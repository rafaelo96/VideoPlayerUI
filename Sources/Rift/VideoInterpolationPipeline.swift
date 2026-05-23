@preconcurrency import AVFoundation
import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import Metal
import QuartzCore

enum VideoInterpolationPipelineError: Error {
    case decoder(String)
    case metal(String)
    case pixelBuffer(String)
    case renderer(String)
}

actor VideoInterpolationPipeline {
    enum InterpolationMode: String, CaseIterable, Sendable {
        case disabled
        case rife2x
        case rife4x
        case rifeAdaptive
        case motion2Intense

        var displayName: String {
            switch self {
            case .disabled: "Off"
            case .rife2x: "RIFE 2x"
            case .rife4x: "RIFE 4x"
            case .rifeAdaptive: "Adaptive"
            case .motion2Intense: "Motion² Intenso"
            }
        }
    }

    struct OutputFrame: @unchecked Sendable {
        let texture: MTLTexture
        let presentationTime: CMTime
        let isInterpolated: Bool
        let processingLatencyMS: Double
    }

    private let sourceURL: URL
    private let rifeEngine: RIFEEngine?
    private let placeboRenderer: PlaceboRenderer?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private var interpolationMode: InterpolationMode
    private var decoder: VideoDecoderEngine?
    private var playbackTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<OutputFrame>.Continuation?
    private let frameStream: AsyncStream<OutputFrame>
    private var previousFrame: DecodedFrame?
    private var isPaused = false
    private var isStopped = true
    private var lastRIFELatencyMS: Double = 0

    var outputFrames: AsyncStream<OutputFrame> {
        frameStream
    }

    init(
        sourceURL: URL,
        rifeEngine: RIFEEngine?,
        placeboRenderer: PlaceboRenderer?,
        interpolationMode: InterpolationMode = .rife2x
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw VideoInterpolationPipelineError.metal("Metal device unavailable")
        }

        var continuation: AsyncStream<OutputFrame>.Continuation?
        self.frameStream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        self.streamContinuation = continuation
        self.sourceURL = sourceURL
        self.rifeEngine = rifeEngine
        self.placeboRenderer = placeboRenderer
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.interpolationMode = interpolationMode
        self.decoder = try await VideoDecoderEngine(url: sourceURL)
    }

    func start() async throws {
        guard playbackTask == nil else {
            isPaused = false
            return
        }

        isStopped = false
        isPaused = false
        playbackTask = Task(priority: .userInteractive) { [weak self] in
            await self?.runDecodeLoop()
        }
    }

    func pause() async {
        isPaused = true
    }

    func resume() async {
        isPaused = false
    }

    func stop() async {
        isStopped = true
        playbackTask?.cancel()
        playbackTask = nil
        previousFrame = nil
    }

    func seek(to time: CMTime) async throws {
        playbackTask?.cancel()
        playbackTask = nil
        previousFrame = nil
        try await decoder?.seek(to: time)
        if !isStopped {
            try await start()
        }
    }

    private func runDecodeLoop() async {
        while !Task.isCancelled && !isStopped {
            if isPaused {
                try? await Task.sleep(nanoseconds: 8_000_000)
                continue
            }

            do {
                guard let decoder else { throw VideoInterpolationPipelineError.decoder("Decoder unavailable") }
                let currentFrame = try await decoder.nextFrame()

                if let previousFrame {
                    try await emit(frame: previousFrame, presentationTime: previousFrame.presentationTime, isInterpolated: false)

                    let shouldInterpolate = try !isSceneCut(previousFrame.pixelBuffer, currentFrame.pixelBuffer)
                    if shouldInterpolate {
                        let frames = try await interpolatedFrames(from: previousFrame, to: currentFrame)
                        for item in frames {
                            try await emit(
                                frame: item.frame,
                                presentationTime: Self.interpolatedTime(from: previousFrame.presentationTime, to: currentFrame.presentationTime, timestep: item.timestep),
                                isInterpolated: true
                            )
                        }
                    }
                }

                previousFrame = currentFrame
            } catch VideoDecoderEngineError.endOfStream {
                if let previousFrame {
                    try? await emit(frame: previousFrame, presentationTime: previousFrame.presentationTime, isInterpolated: false)
                }
                await stop()
            } catch {
                streamContinuation?.finish()
                await stop()
            }
        }
    }

    private func interpolatedFrames(from previous: DecodedFrame, to current: DecodedFrame) async throws -> [(timestep: Float, frame: DecodedFrame)] {
        let timesteps = adaptiveTimesteps()
        guard !timesteps.isEmpty else { return [] }

        if timesteps.count == 1 {
            let start = CACurrentMediaTime()
            let pixelBuffer = try await interpolatePixelBuffer(previous.pixelBuffer, current.pixelBuffer, timestep: timesteps[0])
            lastRIFELatencyMS = (CACurrentMediaTime() - start) * 1000
            return [(
                timesteps[0],
                DecodedFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: Self.interpolatedTime(from: previous.presentationTime, to: current.presentationTime, timestep: timesteps[0]),
                    duration: current.duration,
                    hdrMetadata: previous.hdrMetadata ?? current.hdrMetadata
                )
            )]
        }

        let rifeEngine = self.rifeEngine
        return try await withThrowingTaskGroup(of: (Float, DecodedFrame).self) { group in
            for timestep in timesteps {
                group.addTask(priority: .userInteractive) {
                    let start = CACurrentMediaTime()
                    let pixelBuffer: CVPixelBuffer
                    if let rifeEngine {
                        pixelBuffer = try await rifeEngine.interpolate(frame0: previous.pixelBuffer, frame1: current.pixelBuffer, timestep: timestep)
                    } else {
                        pixelBuffer = try Self.blend(previous.pixelBuffer, current.pixelBuffer, amount: timestep)
                    }
                    let latency = (CACurrentMediaTime() - start) * 1000
                    _ = latency
                    return (
                        timestep,
                        DecodedFrame(
                            pixelBuffer: pixelBuffer,
                            presentationTime: Self.interpolatedTime(from: previous.presentationTime, to: current.presentationTime, timestep: timestep),
                            duration: current.duration,
                            hdrMetadata: previous.hdrMetadata ?? current.hdrMetadata
                        )
                    )
                }
            }

            var result: [(Float, DecodedFrame)] = []
            for try await item in group {
                result.append(item)
            }
            return result.sorted { $0.0 < $1.0 }
        }
    }

    private func interpolatePixelBuffer(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer, timestep: Float) async throws -> CVPixelBuffer {
        if let rifeEngine {
            return try await rifeEngine.interpolate(frame0: frame0, frame1: frame1, timestep: timestep)
        }
        return try Self.blend(frame0, frame1, amount: timestep)
    }

    private func adaptiveTimesteps() -> [Float] {
        switch interpolationMode {
        case .disabled:
            []
        case .rife2x:
            [0.5]
        case .rife4x:
            lastRIFELatencyMS > 14 ? [0.5] : [0.25, 0.5, 0.75]
        case .rifeAdaptive:
            lastRIFELatencyMS > 14 ? [0.5] : [0.25, 0.5, 0.75]
        case .motion2Intense:
            [0.25, 0.5, 0.75]
        }
    }

    private func emit(frame: DecodedFrame, presentationTime: CMTime, isInterpolated: Bool) async throws {
        let start = CACurrentMediaTime()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VideoInterpolationPipelineError.metal("Could not create command buffer")
        }

        let texture = try makeOutputTexture(for: frame.pixelBuffer)
        if let placeboRenderer {
            try placeboRenderer.process(
                frame: frame.pixelBuffer,
                hdrMetadata: frame.hdrMetadata,
                targetTexture: texture,
                commandBuffer: commandBuffer
            )
        } else {
            renderFallback(frame.pixelBuffer, to: texture, commandBuffer: commandBuffer)
        }

        commandBuffer.commit()

        let latency = (CACurrentMediaTime() - start) * 1000
        streamContinuation?.yield(OutputFrame(
            texture: texture,
            presentationTime: presentationTime,
            isInterpolated: isInterpolated,
            processingLatencyMS: latency
        ))
    }

    private func makeOutputTexture(for pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, CVPixelBufferGetWidth(pixelBuffer)),
            height: max(1, CVPixelBufferGetHeight(pixelBuffer)),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw VideoInterpolationPipelineError.metal("Could not allocate output texture")
        }
        return texture
    }

    private func renderFallback(_ pixelBuffer: CVPixelBuffer, to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        ciContext.render(
            image,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private func isSceneCut(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> Bool {
        abs(try Self.averageLuma(a) - Self.averageLuma(b)) > 0.35
    }

    private static func interpolatedTime(from start: CMTime, to end: CMTime, timestep: Float) -> CMTime {
        guard start.isValid, end.isValid else { return start }
        let delta = CMTimeSubtract(end, start)
        return CMTimeAdd(start, CMTimeMultiplyByFloat64(delta, multiplier: Float64(timestep)))
    }

    private static func averageLuma(_ buffer: CVPixelBuffer) throws -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sampleStep = max(1, min(width, height) / 64)
        var sum = 0.0
        var count = 0

        if CVPixelBufferGetPlaneCount(buffer) > 0,
           let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in stride(from: 0, to: height, by: sampleStep) {
                let row = base.advanced(by: y * rowBytes).bindMemory(to: UInt8.self, capacity: rowBytes)
                for x in stride(from: 0, to: width, by: sampleStep) {
                    sum += Double(row[x]) / 255.0
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VideoInterpolationPipelineError.pixelBuffer("Could not lock pixel buffer")
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = base.advanced(by: y * rowBytes).bindMemory(to: UInt8.self, capacity: rowBytes)
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = x * 4
                if format == kCVPixelFormatType_32BGRA {
                    let b = Double(row[offset])
                    let g = Double(row[offset + 1])
                    let r = Double(row[offset + 2])
                    sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
                } else {
                    let r = Double(row[offset + 1])
                    let g = Double(row[offset + 2])
                    let b = Double(row[offset + 3])
                    sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
                }
                count += 1
            }
        }

        return count > 0 ? sum / Double(count) : 0
    }

    private static func blend(_ a: CVPixelBuffer, _ b: CVPixelBuffer, amount: Float) throws -> CVPixelBuffer {
        let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b))
        let height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        let output = try makePixelBuffer(width: width, height: height)
        let context = CIContext(options: [.cacheIntermediates: false])
        let image = CIImage(cvPixelBuffer: a)
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: CIImage(cvPixelBuffer: b),
                kCIInputTimeKey: amount
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(image, to: output)
        return output
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw VideoInterpolationPipelineError.pixelBuffer("CVPixelBufferCreate failed: \(result)")
        }
        return pixelBuffer
    }
}
