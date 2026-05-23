import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

struct RiftPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let fpsMode: FPSMode
    let interpolationMode: VideoInterpolationPipeline.InterpolationMode
    let sourceFrameRate: Double?
    let visualEnhancementsEnabled: Bool
    var onStatsChanged: @MainActor (VideoRenderStats) -> Void = { _ in }

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView()
        context.coordinator.configure(
            view: view,
            player: player,
            fpsMode: fpsMode,
            interpolationMode: interpolationMode,
            sourceFrameRate: sourceFrameRate,
            visualEnhancementsEnabled: visualEnhancementsEnabled,
            onStatsChanged: onStatsChanged
        )
        return view
    }

    func updateNSView(_ view: MetalVideoView, context: Context) {
        context.coordinator.configure(
            view: view,
            player: player,
            fpsMode: fpsMode,
            interpolationMode: interpolationMode,
            sourceFrameRate: sourceFrameRate,
            visualEnhancementsEnabled: visualEnhancementsEnabled,
            onStatsChanged: onStatsChanged
        )
    }

    func makeCoordinator() -> MetalVideoRenderer {
        MetalVideoRenderer()
    }
}

struct VideoRenderStats {
    let renderingFPS: Double
    let isArtificialInterpolationActive: Bool
    let fluxWorkingWidth: Int?
    let opticalFlowUsage: Double
    let blendFallbackUsage: Double
    let rifeStatus: String
    let isRIFELoaded: Bool
}

final class MetalVideoView: MTKView {
    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        framebufferOnly = false
        // Start paused to save energy until a video actually plays
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isPaused = true
            delegate = nil
        }
    }
}

@MainActor
final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private weak var player: AVPlayer?
    private weak var attachedItem: AVPlayerItem?
    private var fpsMode: FPSMode = .native
    private var interpolationMode: VideoInterpolationPipeline.InterpolationMode = .disabled
    private var visualEnhancementsEnabled = false
    private var sourceFrameRate: Double?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var textureCache: CVMetalTextureCache?
    private var framePlusEngine: FramePlusMEMCEngine?
    private var framePlusOutputTexture: MTLTexture?
    private var framePlusOutputPool: CVPixelBuffer?
    private let framePlusInFlightSemaphore = DispatchSemaphore(value: 3)
    private let frameBuffer = AsyncFrameBuffer(capacity: 6)
    private var prefetcher: FramePrefetcher?
    private var framePlusDisplayPulse = 0
    private var framePlusHeldFrame: CVPixelBuffer?
    private var framePlusHeldTime = CMTime.invalid
    private var framePlusNextFrame: SourceVideoFrame?
    private var previousFrame: CVPixelBuffer?
    private var previousFrameTime = CMTime.invalid
    private var latestFrame: CVPixelBuffer?
    private var latestFrameTime = CMTime.invalid
    private var liveInterpolationPair: LiveInterpolationPair?
    private var sourceFrames: [SourceVideoFrame] = []
    private let opticalFlowEngine = OpticalFlowEngine()
    private let rifeInterpolator = RIFECoreMLInterpolator()
    private var isLoadingRIFE = false
    private var rifeInFlight = false
    private var activeRIFEPairKey: String?
    private var rifeFrameCache: [Float: CVPixelBuffer] = [:]
    private var pendingRIFETimesteps: Set<Float> = []
    private var rifeFailureBackoffUntil = 0.0
    private var rifeStabilityBackoffUntil = 0.0
    private var statsHandler: (@MainActor (VideoRenderStats) -> Void)?
    private var statsStartTime = CACurrentMediaTime()
    private var renderedFrameCount = 0
    private var interpolatedFrameCount = 0
    private var opticalFlowFrameCount = 0
    private var blendFallbackFrameCount = 0
    private var fluxWorkingMaxWidth: CGFloat = 1920
    private var sourceFrameIndex = 0
    private var memcDisabledUntil = 0.0
    private var previousAverageLuma: Double?
    private var averageLumaAccumulator = 0.0
    private var averageLumaSamples = 0
    private let rifeWorkingMaxWidth: CGFloat = 1920
    private let rifeWorkingMaxHeight: CGFloat = 1080
    private let memcIntensity = MEMCIntensity.high
    private lazy var memcKernel: CIKernel? = {
        CIKernel(source:
            """
            kernel vec4 memcInterpolate(sampler previousFrame, sampler currentFrame, sampler flowMap, float amount, float maxMotion, float warpStrength, float memcMix, float flowScale, float occlusionThreshold) {
                vec2 dc = destCoord();
                vec4 extent = samplerExtent(currentFrame);
                vec2 minCoord = extent.xy + vec2(0.5);
                vec2 maxCoord = extent.xy + extent.zw - vec2(1.5);
                vec4 flowSample = sample(flowMap, samplerTransform(flowMap, dc));
                vec2 motion = flowSample.xy * flowScale * warpStrength;
                float motionLength = length(motion);

                if (motionLength > maxMotion) {
                    motion = motion * (maxMotion / motionLength);
                }

                vec2 previousCoord = clamp(dc - motion * amount, minCoord, maxCoord);
                vec2 currentCoord = clamp(dc + motion * (1.0 - amount), minCoord, maxCoord);

                vec4 previousColor = sample(previousFrame, samplerTransform(previousFrame, previousCoord));
                vec4 currentColor = sample(currentFrame, samplerTransform(currentFrame, currentCoord));
                vec4 previousOriginal = sample(previousFrame, samplerTransform(previousFrame, dc));
                vec4 currentOriginal = sample(currentFrame, samplerTransform(currentFrame, dc));
                vec4 warped = mix(previousColor, currentColor, amount);
                vec4 dissolved = mix(previousOriginal, currentOriginal, amount);
                float disagreement = distance(previousColor.rgb, currentColor.rgb);
                float confidence = 1.0 - smoothstep(occlusionThreshold * 0.55, occlusionThreshold, disagreement);
                float edgeDistance = min(min(dc.x - minCoord.x, maxCoord.x - dc.x), min(dc.y - minCoord.y, maxCoord.y - dc.y));
                float edgeConfidence = smoothstep(0.0, 72.0, edgeDistance);
                float finalMix = memcMix * confidence * edgeConfidence;

                return mix(dissolved, warped, finalMix);
            }
            """
        )
    }()

    private lazy var fastBlendKernel: CIKernel? = {
        CIKernel(source:
            """
            kernel vec4 fastBlend(sampler previousFrame, sampler currentFrame, float amount) {
                vec2 dc = destCoord();
                vec4 previousColor = sample(previousFrame, samplerTransform(previousFrame, dc));
                vec4 currentColor = sample(currentFrame, samplerTransform(currentFrame, dc));
                return mix(previousColor, currentColor, amount);
            }
            """
        )
    }()

    // Dynamic rendering state observers to shut down GPU cycles when paused.
    // nonisolated(unsafe) is used to safely pass and cleanup OS-level observation tokens in deinit.
    private weak var mtkView: MetalVideoView?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var itemObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var timeObserver: Any?

    deinit {
        // Drain in-flight semaphore to prevent libdispatch crash on dealloc
        // (completion handlers may not have fired yet)
        for _ in 0..<3 {
            framePlusInFlightSemaphore.signal()
        }

        let rObs = rateObservation
        let iObs = itemObservation
        let tObserver = timeObserver
        let p = player
        let v = mtkView

        DispatchQueue.main.async {
            v?.isPaused = true
            v?.delegate = nil
            rObs?.invalidate()
            iObs?.invalidate()
            if let tObserver, let p {
                p.removeTimeObserver(tObserver)
            }
        }
    }

    private func cleanupObservations() {
        stopFramePlusPrefetcher()
        rateObservation = nil
        itemObservation = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        self.timeObserver = nil
    }

    func configure(
        view: MetalVideoView,
        player: AVPlayer,
        fpsMode: FPSMode,
        interpolationMode: VideoInterpolationPipeline.InterpolationMode,
        sourceFrameRate: Double?,
        visualEnhancementsEnabled: Bool,
        onStatsChanged: @escaping @MainActor (VideoRenderStats) -> Void
    ) {
        if self.player !== player {
            cleanupObservations()
            self.player = player
        }
        if self.interpolationMode != interpolationMode {
            resetRIFECache()
            resetFramePlusCadence()
        }

        self.mtkView = view
        self.fpsMode = fpsMode
        self.interpolationMode = interpolationMode
        self.visualEnhancementsEnabled = visualEnhancementsEnabled
        self.sourceFrameRate = sourceFrameRate
        self.statsHandler = onStatsChanged
        view.preferredFramesPerSecond = preferredRenderFPS(fpsMode: fpsMode, interpolationMode: interpolationMode, sourceFrameRate: sourceFrameRate)
        if interpolationMode == .motion2Intense {
            view.preferredFramesPerSecond = 60
            view.isPaused = false
            view.enableSetNeedsDisplay = false
        }
        view.delegate = self

        if commandQueue == nil, let device = view.device {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
            framePlusEngine = try? FramePlusMEMCEngine(device: device)
        }

        attachOutputIfNeeded(to: player.currentItem)
        if interpolationMode != .motion2Intense {
            stopFramePlusPrefetcher()
            loadRIFEIfNeeded()
        } else {
            startFramePlusPrefetcher()
        }
        setupObservations(for: player, in: view)
    }

    private func preferredRenderFPS(
        fpsMode: FPSMode,
        interpolationMode: VideoInterpolationPipeline.InterpolationMode,
        sourceFrameRate: Double?
    ) -> Int {
        guard fpsMode == .flux else {
            return fpsMode.renderFramesPerSecond(sourceFrameRate: sourceFrameRate)
        }

        switch interpolationMode {
        case .disabled:
            return fpsMode.renderFramesPerSecond(sourceFrameRate: sourceFrameRate)
        case .rife2x:
            if let sourceFrameRate, sourceFrameRate > 0 {
                return min(120, max(60, Int((sourceFrameRate * 2).rounded())))
            }
            return 60
        case .motion2Intense:
            return 60
        case .rife4x, .rifeAdaptive:
            return 120
        }
    }

    private func loadRIFEIfNeeded() {
        guard !rifeInterpolator.isLoaded,
              !isLoadingRIFE,
              CACurrentMediaTime() >= rifeFailureBackoffUntil else {
            return
        }

        isLoadingRIFE = true
        Task { @MainActor in
            defer { self.isLoadingRIFE = false }
            do {
                try await self.rifeInterpolator.loadEngine()
            } catch {
                self.rifeFailureBackoffUntil = CACurrentMediaTime() + 3.0
            }
        }
    }

    private func setupObservations(for player: AVPlayer, in view: MetalVideoView) {
        guard timeObserver == nil else {
            updateRenderingState(player: player, view: view)
            return
        }

        // Lightweight main-queue periodic time observer to render single frames during seeks while paused
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.mtkView, let player = self.player else { return }
                if player.timeControlStatus != .playing {
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }

        // Sync initial state
        attachOutputIfNeeded(to: player.currentItem)
        updateRenderingState(player: player, view: view)
    }

    private func updateRenderingState(player: AVPlayer, view: MetalVideoView) {
        if interpolationMode == .motion2Intense, player.currentItem != nil {
            view.preferredFramesPerSecond = 60
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            return
        }

        let isPlaying = player.timeControlStatus == .playing
        
        if isPlaying {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
        } else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay(view.bounds) // Render exactly one static frame at the current playhead
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        autoreleasepool {
            drawFrame(in: view)
        }
    }

    private func drawFrame(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext,
              let output = videoOutput else {
            return
        }
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        if interpolationMode == .motion2Intense {
            drawFramePlus(
                output: output,
                itemTime: itemTime,
                drawable: drawable,
                commandBuffer: commandBuffer,
                ciContext: ciContext,
                view: view
            )
            return
        }

        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.invalid

            if let frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                let oldFrame = latestFrame
                let oldFrameTime = latestFrameTime
                previousFrame = latestFrame
                previousFrameTime = latestFrameTime
                latestFrame = frame
                latestFrameTime = displayTime.isValid ? displayTime : itemTime
                appendSourceFrame(frame, time: latestFrameTime)
                sourceFrameIndex += 1
                if interpolationMode != .motion2Intense {
                    detectSceneChangeIfNeeded(frame)
                }

                if let oldFrame, oldFrameTime.isValid, latestFrameTime.isValid {
                    let duration = latestFrameTime.seconds - oldFrameTime.seconds
                    if duration.isFinite, duration > 0, duration < 0.20 {
                        liveInterpolationPair = LiveInterpolationPair(
                            previous: SourceVideoFrame(pixelBuffer: oldFrame, time: oldFrameTime),
                            next: SourceVideoFrame(pixelBuffer: frame, time: latestFrameTime),
                            startHostTime: hostTime,
                            duration: duration
                        )
                    }
                }

                if fpsMode == .flux,
                   interpolationMode != .motion2Intense,
                   let previousFrame,
                   sourceFrameIndex.isMultiple(of: 3) {
                    opticalFlowEngine.update(
                        previousFrame: previousFrame,
                        currentFrame: frame,
                        pairKey: pairKey(previous: previousFrameTime, next: latestFrameTime)
                    )
                }

                if fpsMode == .flux,
                   interpolationMode != .disabled,
                   interpolationMode != .motion2Intense,
                   let previousFrame {
                    scheduleRIFEIfNeeded(previous: SourceVideoFrame(pixelBuffer: previousFrame, time: previousFrameTime), next: SourceVideoFrame(pixelBuffer: frame, time: latestFrameTime))
                }
            }
        }

        guard let frame = image(for: itemTime, hostTime: hostTime, drawableSize: view.drawableSize) else { return }
        recordRenderedFrame(frame)

        let fittedImage = frame.needsDetailBoost
            ? detailBoosted(aspectFit(frame.image, in: view.drawableSize))
            : aspectFit(frame.image, in: view.drawableSize)
        ciContext.render(
            fittedImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: view.drawableSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawFramePlus(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        ciContext: CIContext,
        view: MTKView
    ) {
        // Pacing GPU: máximo 3 comandos en vuelo evita agotar drawables
        guard framePlusInFlightSemaphore.wait(timeout: .now() + 0.008) == .success else {
            return
        }
        let sema = framePlusInFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            sema.signal()
        }

        // ═══════════════════════════════════════════════════════
        // 1. PRIMING: mínimo 2 frames antes de mostrar
        // ═══════════════════════════════════════════════════════
        if framePlusHeldFrame == nil {
            if frameBuffer.availableCount < 2 {
                ciContext.render(
                    CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: view.drawableSize)),
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: CGRect(origin: .zero, size: view.drawableSize),
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            guard let first = frameBuffer.dequeue() else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            framePlusHeldFrame = first.pixelBuffer
            framePlusHeldTime = first.time
        }

        guard let current = framePlusHeldFrame else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // ═══════════════════════════════════════════════════════
        // 2. CADENCIA: Impar = fuente, Par = interpolación
        // ═══════════════════════════════════════════════════════
        framePlusDisplayPulse &+= 1
        let isInterpolationPulse = framePlusDisplayPulse.isMultiple(of: 2)

        let renderedImage: CIImage
        var isInterpolated = false

        if isInterpolationPulse {
            if framePlusNextFrame == nil {
                framePlusNextFrame = frameBuffer.dequeue()
            }

            if let next = framePlusNextFrame {
                let interpolated = interpolateFrameMetal(
                    current: current,
                    currentTime: framePlusHeldTime,
                    next: next.pixelBuffer,
                    nextTime: next.time,
                    commandBuffer: commandBuffer
                )

                if let interpolated {
                    renderedImage = interpolated
                    isInterpolated = true
                } else {
                    renderedImage = CIImage(cvPixelBuffer: current)
                }

                framePlusHeldFrame = next.pixelBuffer
                framePlusHeldTime = next.time
                framePlusNextFrame = nil
            } else {
                renderedImage = CIImage(cvPixelBuffer: current)
            }
        } else {
            renderedImage = CIImage(cvPixelBuffer: current)
        }

        // ═══════════════════════════════════════════════════════
        // 3. VISUAL ENHANCEMENTS
        // ═══════════════════════════════════════════════════════
        let displayImage = visualEnhancementsEnabled
            ? applyVisualEnhancements(renderedImage)
            : renderedImage

        recordRenderedFrame(InterpolatedImage(
            image: displayImage,
            isInterpolated: isInterpolated,
            needsDetailBoost: false,
            usedOpticalFlow: isInterpolated
        ))

        let fitted = aspectFit(displayImage, in: view.drawableSize)
        ciContext.render(
            fitted,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: view.drawableSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Intenta interpolar dos frames vía Metal Compute (MEMC).
    /// Si falla (engine no disponible, resolución distinta, etc.),
    /// retorna nil y el caller hace frame doubling.
    private func interpolateFrameMetal(
        current: CVPixelBuffer,
        currentTime: CMTime,
        next: CVPixelBuffer,
        nextTime: CMTime,
        commandBuffer: MTLCommandBuffer
    ) -> CIImage? {
        guard let framePlusEngine,
              let device = mtkView?.device,
              let textureCache,
              CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(next),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(next) else {
            return nil
        }

        let w = CVPixelBufferGetWidth(next)
        let h = CVPixelBufferGetHeight(next)
        guard w > 0, h > 0 else { return nil }

        // Reusar CVPixelBuffer de output (evita CIImage(mtlTexture:) que da geometría incorrecta en macOS)
        if framePlusOutputPool == nil ||
            CVPixelBufferGetWidth(framePlusOutputPool!) != w ||
            CVPixelBufferGetHeight(framePlusOutputPool!) != h {
            let attrs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            framePlusOutputPool = pb
            framePlusOutputTexture = nil
        }

        guard let pixelBuffer = framePlusOutputPool else { return nil }

        // Crear MTLTexture desde el CVPixelBuffer vía textureCache
        if framePlusOutputTexture == nil {
            var texRef: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, w, h, 0, &texRef
            )
            framePlusOutputTexture = texRef.flatMap { CVMetalTextureGetTexture($0) }
        }

        guard let outputTexture = framePlusOutputTexture else { return nil }

        do {
            try framePlusEngine.encode(
                previous: current,
                current: next,
                output: outputTexture,
                commandBuffer: commandBuffer,
                timestep: 0.5
            )
        } catch {
            return nil
        }

        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    private func copyFrame(from output: AVPlayerItemVideoOutput, itemTime: CMTime) -> SourceVideoFrame? {
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }

        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
            return nil
        }

        let time = displayTime.isValid ? displayTime : itemTime
        return SourceVideoFrame(pixelBuffer: pixelBuffer, time: time)
    }

    private func startFramePlusPrefetcher() {
        guard prefetcher == nil, let output = videoOutput else { return }
        frameBuffer.reset()
        let p = FramePrefetcher(output: output, buffer: frameBuffer)
        p.start()
        prefetcher = p
    }

    private func stopFramePlusPrefetcher() {
        prefetcher?.stop()
        prefetcher = nil
        frameBuffer.reset()
        framePlusNextFrame = nil
    }

    private func dequeueFramePlusFrame() -> SourceVideoFrame? {
        frameBuffer.dequeue()
    }

    private func resetFramePlusCadence() {
        framePlusHeldFrame = nil
        framePlusHeldTime = .invalid
        framePlusNextFrame = nil
        framePlusDisplayPulse = 0
        frameBuffer.reset()
    }

    // DIRECTIVA 2: CVMetalTextureCache — mapeo instantáneo CVPixelBuffer → MTLTexture
    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard attachedItem !== item else { return }

        if let videoOutput, let attachedItem {
            attachedItem.remove(videoOutput)
        }
        stopFramePlusPrefetcher()

        attachedItem = item
        previousFrame = nil
        previousFrameTime = .invalid
        latestFrame = nil
        latestFrameTime = .invalid
        liveInterpolationPair = nil
        framePlusHeldFrame = nil
        framePlusHeldTime = .invalid
        framePlusNextFrame = nil
        framePlusDisplayPulse = 0
        frameBuffer.reset()
        sourceFrames.removeAll(keepingCapacity: true)
        sourceFrameIndex = 0
        memcDisabledUntil = 0
        opticalFlowEngine.reset()
        previousAverageLuma = nil
        averageLumaAccumulator = 0
        averageLumaSamples = 0
        resetStats()
        resetRIFECache()

        guard let item else {
            videoOutput = nil
            return
        }

        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        item.add(output)
        videoOutput = output
        if interpolationMode == .motion2Intense {
            startFramePlusPrefetcher()
        }
    }

    private func image(for itemTime: CMTime, hostTime: CFTimeInterval, drawableSize: CGSize) -> InterpolatedImage? {
        guard let latestSourceFrame = sourceFrames.last ?? latestFrame.map({ SourceVideoFrame(pixelBuffer: $0, time: latestFrameTime) }) else {
            return nil
        }

        guard fpsMode == .flux else {
            return InterpolatedImage(
                image: CIImage(cvPixelBuffer: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let pair: (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double)
        if interpolationMode == .motion2Intense, let livePair = liveInterpolationPair {
            let phase = min(max((hostTime - livePair.startHostTime) / livePair.duration, 0), 0.985)
            pair = (
                previous: livePair.previous,
                next: livePair.next,
                targetSeconds: livePair.previous.time.seconds + livePair.duration * phase
            )
        } else if let bufferedPair = sourceFramePair(for: itemTime) {
            pair = bufferedPair
        } else {
            return InterpolatedImage(
                image: CIImage(cvPixelBuffer: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let frameDuration = pair.next.time.seconds - pair.previous.time.seconds
        guard frameDuration.isFinite, frameDuration > 0 else {
            return InterpolatedImage(
                image: CIImage(cvPixelBuffer: latestSourceFrame.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let t = min(max((pair.targetSeconds - pair.previous.time.seconds) / frameDuration, 0), 0.985)

        // Only produce interpolated frames in the middle of the inter-frame window.
        // Values near 0 or 1 map almost exactly to a source frame anyway — skip blend.
        guard t > 0.01 && t < 0.99 else {
            return InterpolatedImage(
                image: CIImage(cvPixelBuffer: pair.next.pixelBuffer),
                isInterpolated: false,
                needsDetailBoost: false,
                usedOpticalFlow: false
            )
        }

        let interpolationWidth = fluxInterpolationWidth(for: pair.previous.pixelBuffer)

        if let rifeImage = rifeImage(for: pair, amount: t) {
            return InterpolatedImage(
                image: rifeImage,
                isInterpolated: true,
                needsDetailBoost: false,
                usedOpticalFlow: true
            )
        }

        let prevCI = scaledToWidth(CIImage(cvPixelBuffer: pair.previous.pixelBuffer), width: interpolationWidth)
        let nextCI = scaledToWidth(CIImage(cvPixelBuffer: pair.next.pixelBuffer), width: interpolationWidth)
        let result = interpolatedImage(
            previousImage: prevCI,
            currentImage: nextCI,
            amount: t,
            pairKey: pairKey(previous: pair.previous.time, next: pair.next.time),
            allowOpticalFlow: interpolationMode != .motion2Intense
        )

        return InterpolatedImage(
            image: result.image,
            isInterpolated: true,
            needsDetailBoost: false,
            usedOpticalFlow: result.usedOpticalFlow || interpolationMode == .motion2Intense
        )
    }

    private func interpolatedImage(previousImage: CIImage, currentImage: CIImage, amount: Double, pairKey: String, allowOpticalFlow: Bool) -> MEMCImage {
        if allowOpticalFlow,
           CACurrentMediaTime() >= memcDisabledUntil,
            let flow = opticalFlowEngine.snapshotFlow(maxAge: 0.42, pairKey: pairKey),
           let memcImage = opticalFlowImage(previousImage: previousImage, currentImage: currentImage, flow: flow, amount: amount) {
            return MEMCImage(image: memcImage, usedOpticalFlow: true)
        }

        let blend = fastBlendKernel?.apply(
            extent: currentImage.extent,
            roiCallback: { _, rect in rect },
            arguments: [
                previousImage,
                currentImage,
                Float(amount)
            ]
        )?.cropped(to: currentImage.extent) ?? currentImage

        return MEMCImage(image: blend, usedOpticalFlow: false)
    }

    private func scheduleRIFEIfNeeded(previous: SourceVideoFrame, next: SourceVideoFrame) {
        guard rifeInterpolator.isLoaded else {
            loadRIFEIfNeeded()
            return
        }
        guard !rifeInFlight,
              CACurrentMediaTime() >= rifeFailureBackoffUntil,
              CACurrentMediaTime() >= rifeStabilityBackoffUntil else {
            return
        }

        let key = pairKey(previous: previous.time, next: next.time)
        if activeRIFEPairKey != key {
            activeRIFEPairKey = key
            rifeFrameCache.removeAll(keepingCapacity: true)
            pendingRIFETimesteps.removeAll(keepingCapacity: true)
        }

        guard let timestep = desiredRIFETimesteps().first(where: { rifeFrameCache[$0] == nil && !pendingRIFETimesteps.contains($0) }),
              let preparedPrevious = preparedRIFEBuffer(from: previous.pixelBuffer),
              let preparedNext = preparedRIFEBuffer(from: next.pixelBuffer) else {
            return
        }

        rifeInFlight = true
        pendingRIFETimesteps.insert(timestep)
        Task { @MainActor in
            let start = CACurrentMediaTime()
            defer {
                self.pendingRIFETimesteps.remove(timestep)
                self.rifeInFlight = false
            }
            do {
                let interpolated = try await self.rifeInterpolator.interpolate(
                    frame0: preparedPrevious,
                    frame1: preparedNext,
                    timestep: timestep
                )

                if self.activeRIFEPairKey == key {
                    self.rifeFrameCache[timestep] = interpolated
                }

                let latencyMS = (CACurrentMediaTime() - start) * 1000
                if latencyMS > 180 {
                    self.rifeFailureBackoffUntil = CACurrentMediaTime() + 0.75
                }
            } catch {
                self.rifeFailureBackoffUntil = CACurrentMediaTime() + 2.5
            }
        }
    }

    private func preparedRIFEBuffer(from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        guard sourceWidth <= rifeWorkingMaxWidth, sourceHeight <= rifeWorkingMaxHeight else {
            return nil
        }

        let width = max(32, Int(sourceWidth.rounded()))
        let height = max(32, Int(sourceHeight.rounded()))
        let alignedWidth = width
        let alignedHeight = height

        if alignedWidth == Int(sourceWidth), alignedHeight == Int(sourceHeight), CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            return pixelBuffer
        }

        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            alignedWidth,
            alignedHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        ciContext?.render(image, to: output)
        return output
    }

    private func rifeImage(
        for pair: (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double),
        amount: Double
    ) -> CIImage? {
        guard interpolationMode != .disabled,
              activeRIFEPairKey == pairKey(previous: pair.previous.time, next: pair.next.time),
              !rifeFrameCache.isEmpty else {
            return nil
        }

        let timestep = nearestRIFETimestep(to: amount)
        guard let frame = rifeFrameCache[timestep] else { return nil }
        return CIImage(cvPixelBuffer: frame)
    }

    private func desiredRIFETimesteps() -> [Float] {
        switch interpolationMode {
        case .disabled:
            []
        case .rife2x:
            [0.5]
        case .rife4x:
            [0.25, 0.5, 0.75]
        case .rifeAdaptive:
            currentRenderFPSEstimate() >= 85 ? [0.25, 0.5, 0.75] : [0.5]
        case .motion2Intense:
            []
        }
    }

    private func nearestRIFETimestep(to amount: Double) -> Float {
        let timesteps = desiredRIFETimesteps()
        guard let nearest = timesteps.min(by: { abs(Double($0) - amount) < abs(Double($1) - amount) }) else {
            return 0.5
        }
        return nearest
    }

    private func currentRenderFPSEstimate() -> Double {
        let elapsed = CACurrentMediaTime() - statsStartTime
        guard elapsed > 0.05 else { return 0 }
        return Double(renderedFrameCount) / elapsed
    }

    private func pairKey(previous: CMTime, next: CMTime) -> String {
        "\(previous.value)/\(previous.timescale)-\(next.value)/\(next.timescale)"
    }

    private func resetRIFECache() {
        activeRIFEPairKey = nil
        rifeFrameCache.removeAll(keepingCapacity: true)
        pendingRIFETimesteps.removeAll(keepingCapacity: true)
    }

    private func appendSourceFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard time.isValid, time.seconds.isFinite else { return }

        if let last = sourceFrames.last {
            let delta = time.seconds - last.time.seconds
            if abs(delta) < 0.0005 {
                sourceFrames[sourceFrames.count - 1] = SourceVideoFrame(pixelBuffer: pixelBuffer, time: time)
                return
            }

            if delta < 0 || delta > 0.75 {
                sourceFrames.removeAll(keepingCapacity: true)
            }
        }

        sourceFrames.append(SourceVideoFrame(pixelBuffer: pixelBuffer, time: time))
        if sourceFrames.count > 8 {
            sourceFrames.removeFirst(sourceFrames.count - 8)
        }
    }

    private func sourceFramePair(for itemTime: CMTime) -> (previous: SourceVideoFrame, next: SourceVideoFrame, targetSeconds: Double)? {
        guard sourceFrames.count >= 2 else { return nil }

        let delay = estimatedSourceFrameDuration()
        let targetSeconds = itemTime.seconds - delay

        for index in 0..<(sourceFrames.count - 1) {
            let previous = sourceFrames[index]
            let next = sourceFrames[index + 1]
            if targetSeconds >= previous.time.seconds && targetSeconds <= next.time.seconds {
                return (previous, next, targetSeconds)
            }
        }

        if targetSeconds < sourceFrames[0].time.seconds {
            return (sourceFrames[0], sourceFrames[1], sourceFrames[0].time.seconds)
        }

        let previous = sourceFrames[sourceFrames.count - 2]
        let next = sourceFrames[sourceFrames.count - 1]
        return (previous, next, min(targetSeconds, next.time.seconds - 0.0001))
    }

    private func estimatedSourceFrameDuration() -> Double {
        if sourceFrames.count >= 2 {
            let newest = sourceFrames[sourceFrames.count - 1].time.seconds
            let previous = sourceFrames[sourceFrames.count - 2].time.seconds
            let delta = newest - previous
            if delta.isFinite, delta > 0 {
                return min(max(delta * 1.12, delta), 0.10)
            }
        }

        if let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 {
            return 1.12 / sourceFrameRate
        }

        return 1.0 / 24.0
    }

    private func opticalFlowImage(previousImage: CIImage, currentImage: CIImage, flow: OpticalFlowSnapshot, amount: Double) -> CIImage? {
        guard let memcKernel else { return nil }

        let rawFlowImage = CIImage(cvPixelBuffer: flow.pixelBuffer)
        let flowImage = scaledFlowImage(rawFlowImage, to: currentImage.extent)

        return memcKernel.apply(
            extent: currentImage.extent,
            roiCallback: { _, rect in
                rect.insetBy(dx: -96, dy: -96)
            },
            arguments: [
                previousImage,
                currentImage,
                flowImage,
                Float(amount),
                Float(memcIntensity.maxMotion),
                Float(memcIntensity.warpStrength),
                Float(memcIntensity.mix),
                effectiveFlowScale(for: flow, currentImage: currentImage),
                Float(memcIntensity.occlusionThreshold)
            ]
        )?.cropped(to: currentImage.extent)
    }

    private func scaledFlowImage(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0,
              image.extent.height > 0,
              extent.width > 0,
              extent.height > 0 else {
            return image
        }

        let scaleX = extent.width / image.extent.width
        let scaleY = extent.height / image.extent.height
        let transform = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: extent.origin.x - image.extent.origin.x * scaleX,
            ty: extent.origin.y - image.extent.origin.y * scaleY
        )

        return image
            .transformed(by: transform)
            .cropped(to: extent)
    }

    private func effectiveFlowScale(for flow: OpticalFlowSnapshot, currentImage: CIImage) -> Float {
        let sourceWidth = max(1, flow.sourceWidth)
        let workingScale = currentImage.extent.width / CGFloat(sourceWidth)
        return flow.vectorScale * Float(workingScale)
    }

    private func detectSceneChangeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard sourceFrameIndex.isMultiple(of: 6) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else { return }
        averageFilter.setValue(image, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let outputImage = averageFilter.outputImage else { return }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext?.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let luma = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255.0
        averageLumaAccumulator += luma
        averageLumaSamples += 1

        if let previousAverageLuma, abs(luma - previousAverageLuma) > 0.20 {
            memcDisabledUntil = CACurrentMediaTime() + 0.8
            opticalFlowEngine.reset()
        }

        previousAverageLuma = luma
    }

    private func recordRenderedFrame(_ frame: InterpolatedImage) {
        renderedFrameCount += 1
        if frame.isInterpolated {
            interpolatedFrameCount += 1
            if frame.usedOpticalFlow {
                opticalFlowFrameCount += 1
            } else {
                blendFallbackFrameCount += 1
            }
        }

        let now = CACurrentMediaTime()
        let elapsed = now - statsStartTime
        guard elapsed >= 0.5 else { return }

        let renderingFPS = Double(renderedFrameCount) / elapsed
        if interpolationMode != .disabled, renderingFPS < 55 {
            rifeStabilityBackoffUntil = CACurrentMediaTime() + 3.0
            resetRIFECache()
        }
        let isInterpolationActive = interpolatedFrameCount > 0
        let opticalFlowUsage = interpolatedFrameCount > 0
            ? Double(opticalFlowFrameCount) / Double(interpolatedFrameCount)
            : 0
        let blendFallbackUsage = interpolatedFrameCount > 0
            ? Double(blendFallbackFrameCount) / Double(interpolatedFrameCount)
            : 0
        statsHandler?(
            VideoRenderStats(
                renderingFPS: renderingFPS,
                isArtificialInterpolationActive: isInterpolationActive,
                fluxWorkingWidth: fpsMode == .flux ? Int(fluxWorkingMaxWidth.rounded()) : nil,
                opticalFlowUsage: opticalFlowUsage,
                blendFallbackUsage: blendFallbackUsage,
                rifeStatus: rifeInterpolator.statusText,
                isRIFELoaded: rifeInterpolator.isLoaded
            )
        )
        resetStats()
    }

    private func resetStats() {
        statsStartTime = CACurrentMediaTime()
        renderedFrameCount = 0
        interpolatedFrameCount = 0
        opticalFlowFrameCount = 0
        blendFallbackFrameCount = 0
    }

    private func applyVisualEnhancements(_ image: CIImage) -> CIImage {
        var output = image

        output = output
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.72,
                "inputShadowAmount": 0.12
            ])

        output = output
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.96,
                kCIInputContrastKey: 1.01
            ])
            .cropped(to: image.extent)

        return output
    }

    private func aspectFill(_ image: CIImage, in drawableSize: CGSize) -> CIImage {
        guard image.extent.width > 0,
              image.extent.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return image
        }

        let scale = max(drawableSize.width / image.extent.width, drawableSize.height / image.extent.height)
        let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let offset = CGPoint(
            x: (drawableSize.width - scaledSize.width) * 0.5,
            y: (drawableSize.height - scaledSize.height) * 0.5
        )

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .cropped(to: CGRect(origin: .zero, size: drawableSize))
    }

    private func aspectFit(_ image: CIImage, in drawableSize: CGSize) -> CIImage {
        guard image.extent.width > 0,
              image.extent.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return image
        }

        let scale = min(drawableSize.width / image.extent.width, drawableSize.height / image.extent.height)
        let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let offset = CGPoint(
            x: (drawableSize.width - scaledSize.width) * 0.5,
            y: (drawableSize.height - scaledSize.height) * 0.5
        )

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    }

    private func fluxInterpolationWidth(for frame: CVPixelBuffer) -> CGFloat {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(frame))
        guard sourceWidth > 0 else { return fluxWorkingMaxWidth }
        return min(sourceWidth, fluxWorkingMaxWidth)
    }

    private func scaledToWidth(_ image: CIImage, width: CGFloat) -> CIImage {
        guard image.extent.width > 0, width > 0 else { return image }
        let scale = width / image.extent.width
        let scaledHeight = image.extent.height * scale

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: scaledHeight))
    }

    private func detailBoosted(_ image: CIImage) -> CIImage {
        image
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.35
            ])
            .cropped(to: image.extent)
    }

}

private struct InterpolatedImage {
    let image: CIImage
    let isInterpolated: Bool
    let needsDetailBoost: Bool
    let usedOpticalFlow: Bool
}

private struct LiveInterpolationPair {
    let previous: SourceVideoFrame
    let next: SourceVideoFrame
    let startHostTime: CFTimeInterval
    let duration: Double
}

private struct MEMCImage {
    let image: CIImage
    let usedOpticalFlow: Bool
}

private enum MEMCIntensity {
    case high

    var maxMotion: Double {
        switch self {
        case .high: 36
        }
    }

    var warpStrength: Double {
        switch self {
        case .high: 0.62
        }
    }

    var mix: Double {
        switch self {
        case .high: 0.76
        }
    }

    var occlusionThreshold: Double {
        switch self {
        case .high: 0.50
        }
    }
}
