import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerState: ObservableObject {
    // A single AVPlayer instance is shared between the video layer and SwiftUI controls.
    let player = AVPlayer()

    @Published var fileName = "Video.mp4"
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.72
    @Published var playbackRate: Float = 1.0
    @Published var fpsMode: FPSMode = .native
    @Published var hasVideo = false
    @Published var statusMessage: String?
    @Published var videoCodec: String? = nil
    @Published var audioCodec: String? = nil
    @Published var videoResolution: String? = nil
    @Published var sourceFrameRate: Double? = nil
    @Published var currentRenderingFPS: Double = 0.0
    @Published var isArtificialInterpolationActive = false
    @Published var fluxWorkingWidth: Int? = nil
    @Published var fluxOpticalFlowUsage: Double = 0.0
    @Published var fluxBlendFallbackUsage: Double = 0.0
    @Published var rifeStatus: String = "RIFE sin modelo"
    @Published var isRIFELoaded = false
    @Published var audioTracks: [AudioTrack] = []
    @Published var selectedAudioTrackIndex: Int = 0
    @Published var url: URL?
    @Published var interpolationMode: VideoInterpolationPipeline.InterpolationMode = .motion2Intense
    @Published var isFramePlusPreparing = false
    @Published var isFramePlusPreRendered = false
    @Published var visualEnhancementsEnabled = false
    @Published var rifeEnabled: Bool = false
    @Published var metrics = PlaybackMetrics()
    @Published var availableTracks: [MediaTrack] = []
    @Published var selectedAudioTrack: MediaTrack?
    @Published var selectedSubtitleTrack: MediaTrack?
    @Published var hdrMetadata: HDRMetadata?
    @Published var isHDRContent = false

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var conversionProcess: Process?
    private var convertedVideoURL: URL?
    private var originalVideoURL: URL?
    private var playbackSourceURL: URL?
    private let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
    private let containerFormatsNeedingConversion: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts"]

    var displayRenderingFPS: Double {
        if isFramePlusPreRendered { return 60 }
        if isFramePlusPreparing { return sourceFrameRate ?? 24 }
        if currentRenderingFPS > 0 { return currentRenderingFPS }
        return sourceFrameRate ?? 0
    }

    init() {
        player.volume = Float(volume)
        addTimeObserver()

        if CommandLine.arguments.contains("--fps=60") {
            fpsMode = .flux
        }

        if let path = CommandLine.arguments.first(where: { !$0.hasPrefix("--") && $0 != CommandLine.arguments.first }) {
            Task { @MainActor in
                self.loadVideo(URL(fileURLWithPath: path))
            }
        }
    }

    func cleanup() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        conversionProcess?.terminate()
        conversionProcess = nil
        itemStatusObservation = nil
        cleanupConvertedVideo()
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let boundedSeconds = max(0, min(seconds, duration))
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = boundedSeconds
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(value, 1))
        player.volume = Float(volume)
    }

    func cyclePlaybackRate() {
        // Cycles through the exact speed states requested by the UI spec.
        let currentIndex = rates.firstIndex(of: playbackRate) ?? 0
        playbackRate = rates[(currentIndex + 1) % rates.count]

        if isPlaying {
            player.rate = playbackRate
        }
    }

    func cycleFPSMode() {
        withAnimation(.easeInOut(duration: 0.22)) {
            fpsMode = fpsMode.next
        }
    }

    func setInterpolationMode(_ mode: VideoInterpolationPipeline.InterpolationMode) {
        let requiresRIFE = mode == .rife2x || mode == .rife4x || mode == .rifeAdaptive
        guard mode == .disabled || mode == .motion2Intense || (requiresRIFE && isRIFELoaded) else {
            interpolationMode = .disabled
            rifeEnabled = false
            fpsMode = .native
            statusMessage = "RIFE no disponible: falta RIFE.mlpackage"
            return
        }

        if mode == .disabled {
            isFramePlusPreparing = false
            isFramePlusPreRendered = false
        }

        interpolationMode = mode
        rifeEnabled = requiresRIFE && isRIFELoaded
        fpsMode = mode == .disabled ? .native : .flux

        if mode == .motion2Intense {
            isFramePlusPreparing = false
            isFramePlusPreRendered = false
        }
    }

    func selectPipelineTrack(_ track: MediaTrack?) {
        guard let track else {
            selectedSubtitleTrack = nil
            return
        }

        switch track.kind {
        case .audio:
            selectedAudioTrack = track
        case .subtitle:
            selectedSubtitleTrack = track
        case .video:
            break
        }
    }

    func selectAudioTrack(_ index: Int) {
        guard index < audioTracks.count else { return }
        guard let item = player.currentItem else { return }
        Task {
            guard let allTracks = try? await item.asset.loadTracks(withMediaType: .audio) else { return }
            await MainActor.run {
                self.selectedAudioTrackIndex = index
                self.applyAudioMix(trackIndex: index, to: item, allTracks: allTracks)
            }
        }
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    func loadVideo(_ url: URL) {
        self.url = url
        originalVideoURL = url
        playbackSourceURL = nil
        isFramePlusPreparing = false
        isFramePlusPreRendered = false
        conversionProcess?.terminate()
        conversionProcess = nil
        cleanupConvertedVideo()

        videoCodec = nil
        audioCodec = nil
        videoResolution = nil
        sourceFrameRate = nil
        currentRenderingFPS = 0.0
        isArtificialInterpolationActive = false
        fluxWorkingWidth = nil
        fluxOpticalFlowUsage = 0.0
        fluxBlendFallbackUsage = 0.0
        rifeStatus = "RIFE sin modelo"
        isRIFELoaded = false
        audioTracks = []
        selectedAudioTrackIndex = 0
        availableTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        hdrMetadata = nil
        isHDRContent = false
        metrics = PlaybackMetrics()

        if needsConversion(url) {
            Task { @MainActor in
                await convertAndLoadVideo(url)
            }
            return
        }

        Task { @MainActor in
            await prepareVideoMetadata(for: url)
        }
        playVideo(url, displayName: url.lastPathComponent)
    }

    private func prepareVideoMetadata(for url: URL) async {
        let streams = await inspectCodecs(for: url)
        await MainActor.run {
            let videoStream = streams.first { $0.codecType == "video" }
            let audioStream = streams.first { $0.codecType == "audio" }
            
            self.videoCodec = videoStream?.codecName.uppercased()
            self.audioCodec = audioStream?.codecName.uppercased()
            
            if let w = videoStream?.width, let h = videoStream?.height {
                self.videoResolution = "\(w)x\(h)"
            } else {
                self.videoResolution = nil
            }
            self.sourceFrameRate = videoStream?.frameRate
        }
    }

    private func playVideo(_ url: URL, displayName: String) {
        playbackSourceURL = url
        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }

                switch item.status {
                case .unknown:
                    break
                case .readyToPlay:
                    self.statusMessage = nil
                    self.loadAudioTracks(from: item)
                    self.player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                case .failed:
                    self.statusMessage = "No se pudo cargar el video convertido."
                    self.isPlaying = false
                @unknown default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)

        fileName = displayName.isEmpty ? "Video.mp4" : displayName
        currentTime = 0
        duration = 0
        isPlaying = false
        hasVideo = true
        statusMessage = nil

        Task {
            let loadedDuration = try? await item.asset.load(.duration)
            await MainActor.run {
                duration = loadedDuration?.seconds.isFinite == true ? loadedDuration?.seconds ?? 0 : 0
            }
        }
    }

    private func needsConversion(_ url: URL) -> Bool {
        containerFormatsNeedingConversion.contains(url.pathExtension.lowercased())
    }

    struct AudioTrack: Identifiable {
        let id: Int
        let label: String
        let language: String?
    }

    struct StreamInfo {
        let codecName: String
        let codecType: String
        let width: Int?
        let height: Int?
        let frameRate: Double?
    }

    struct PlaybackMetrics {
        var actualFPS: Double = 0
        var rifeLatencyMS: Double = 0
        var placeboLatencyMS: Double = 0
        var droppedFrames: Int = 0
        var interpolatedFrames: Int = 0
        var totalFrames: Int = 0
    }

    private func inspectCodecs(for url: URL) async -> [StreamInfo] {
        guard let ffprobeURL = findFFprobe() else { return [] }
        
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_name,codec_type,width,height,avg_frame_rate",
            "-of", "csv=p=0",
            url.path
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: d)
                }
            }
            
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return [] }
            
            if let output = String(data: data, encoding: .utf8) {
                var streams: [StreamInfo] = []
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.split(separator: ",")
                    if parts.count >= 2 {
                        let codecName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let codecType = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        
                        var width: Int? = nil
                        var height: Int? = nil
                        
                        if parts.count >= 4 {
                            width = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
                            height = Int(parts[3].trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        
                        let frameRate = parts.count >= 5
                            ? Self.parseFrameRate(String(parts[4]))
                            : nil

                        streams.append(StreamInfo(
                            codecName: codecName,
                            codecType: codecType,
                            width: width,
                            height: height,
                            frameRate: frameRate
                        ))
                    }
                }
                return streams
            }
        } catch {
            return []
        }
        return []
    }

    private func convertAndLoadVideo(_ sourceURL: URL) async {
        guard let ffmpegURL = findFFmpeg() else {
            statusMessage = "Para reproducir MKV instala ffmpeg: brew install ffmpeg"
            hasVideo = false
            return
        }

        statusMessage = "Inspeccionando archivo..."
        hasVideo = false
        fileName = sourceURL.lastPathComponent

        // Inspeccionar códecs
        let streams = await inspectCodecs(for: sourceURL)
        let videoStream = streams.first { $0.codecType == "video" }
        let audioStream = streams.first { $0.codecType == "audio" }
        
        let videoCodec = videoStream?.codecName
        let audioCodec = audioStream?.codecName
        
        let isVideoCopyable = videoCodec == "h264" || videoCodec == "hevc" || videoCodec == "h265"
        let isAudioCopyable = audioCodec == "aac" || audioCodec == "mp3" || audioCodec == "ac3" || audioCodec == "eac3" || audioCodec == "flac" || audioCodec == "alac"
        let mp4VideoTagArgs = (videoCodec == "hevc" || videoCodec == "h265") ? ["-tag:v", "hvc1"] : []

        await MainActor.run {
            self.videoCodec = videoCodec?.uppercased()
            self.audioCodec = audioCodec?.uppercased()
            if let w = videoStream?.width, let h = videoStream?.height {
                self.videoResolution = "\(w)x\(h)"
            } else {
                self.videoResolution = nil
            }
            self.sourceFrameRate = videoStream?.frameRate
        }

        statusMessage = "Preparando \(sourceURL.pathExtension.uppercased())..."

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiquidPlayer-\(UUID().uuidString).mp4")

        convertedVideoURL = outputURL

        var ffmpegArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-dn"
        ]

        if isVideoCopyable && isAudioCopyable {
            ffmpegArgs += [
                "-c", "copy",
            ] + mp4VideoTagArgs + [
                "-y", outputURL.path
            ]
            let success = await runFFmpegAsync(ffmpegURL, arguments: ffmpegArgs, phase: "Preparando video")
            if success {
                self.playVideo(outputURL, displayName: sourceURL.lastPathComponent)
                return
            }
        } else if isVideoCopyable && !isAudioCopyable {
            ffmpegArgs += [
                "-c:v", "copy",
            ] + mp4VideoTagArgs + [
                "-c:a", "aac",
                "-b:a", "192k",
                "-y", outputURL.path
            ]
            let success = await runFFmpegAsync(ffmpegURL, arguments: ffmpegArgs, phase: "Convirtiendo audio")
            if success {
                self.playVideo(outputURL, displayName: sourceURL.lastPathComponent)
                return
            }
        }

        // Transcodificar video usando GPU acelerada
        statusMessage = "Convirtiendo video (hardware)..."
        var hwArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-dn",
            "-c:v", "h264_videotoolbox",
            "-b:v", "8M",
            "-pix_fmt", "yuv420p"
        ]
        if isAudioCopyable {
            hwArgs += ["-c:a", "copy"]
        } else {
            hwArgs += ["-c:a", "aac", "-b:a", "192k"]
        }
        hwArgs += ["-y", outputURL.path]

        let hwSuccess = await runFFmpegAsync(ffmpegURL, arguments: hwArgs, phase: "Convirtiendo video")
        if hwSuccess {
            self.playVideo(outputURL, displayName: sourceURL.lastPathComponent)
            return
        }

        // Fallback: transcodificación por software
        statusMessage = "Convirtiendo video (compatible)..."
        var swArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-dn",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "20",
            "-pix_fmt", "yuv420p"
        ]
        if isAudioCopyable {
            swArgs += ["-c:a", "copy"]
        } else {
            swArgs += ["-c:a", "aac", "-b:a", "192k"]
        }
        swArgs += ["-y", outputURL.path]

        let swSuccess = await runFFmpegAsync(ffmpegURL, arguments: swArgs, phase: "Convirtiendo compatible")
        if swSuccess {
            self.playVideo(outputURL, displayName: sourceURL.lastPathComponent)
        } else {
            self.statusMessage = "No se pudo convertir este video."
            self.hasVideo = false
            self.cleanupConvertedVideo()
        }
    }

    private func prepareFramePlusVideo(from sourceURL: URL) async {
        guard !isFramePlusPreparing else { return }
        guard let ffmpegURL = findFFmpeg() else {
            statusMessage = "Frame⁺ necesita ffmpeg."
            interpolationMode = .disabled
            fpsMode = .native
            return
        }

        isFramePlusPreparing = true
        isFramePlusPreRendered = false
        statusMessage = "Frame⁺ preparando 60fps..."

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiquidPlayer-FramePlus-\(UUID().uuidString).mp4")
        convertedVideoURL = outputURL

        let args = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-dn",
            "-vf", "minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
            "-c:v", "hevc_videotoolbox",
            "-tag:v", "hvc1",
            "-b:v", "18M",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-y", outputURL.path
        ]

        let success = await runFFmpegAsync(ffmpegURL, arguments: args, phase: "Frame⁺ renderizando 60fps")
        isFramePlusPreparing = false

        if success {
            isFramePlusPreRendered = true
            fpsMode = .native
            sourceFrameRate = 60
            currentRenderingFPS = 60
            isArtificialInterpolationActive = true
            playVideo(outputURL, displayName: "\(fileName) · Frame⁺ 60fps")
        } else {
            statusMessage = "Frame⁺ no pudo preparar 60fps."
            interpolationMode = .disabled
            fpsMode = .native
            isFramePlusPreRendered = false
        }
    }

    private func runFFmpegAsync(_ executableURL: URL, arguments: [String], phase: String) async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-nostdin"] + arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        conversionProcess = process
        
        if let outputPath = arguments.last {
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let startTime = Date()
        
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard process.isRunning else { break }
                let elapsedSeconds = Int(Date().timeIntervalSince(startTime))
                self.statusMessage = "\(phase)... \(elapsedSeconds)s"
            }
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                let success = process.terminationStatus == 0
                _ = errorPipe.fileHandleForReading.readDataToEndOfFile()

                Task { @MainActor in
                    progressTask.cancel()
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.conversionProcess = nil
                    continuation.resume(returning: success)
                }
            }

            do {
                try process.run()
            } catch {
                progressTask.cancel()
                Task { @MainActor in
                    self.conversionProcess = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func loadAudioTracks(from item: AVPlayerItem) {
        Task {
            // AVAssetTrack is the reliable API for local files (including FFmpeg-converted MP4s).
            // AVMediaSelectionGroup only works for HLS and some native containers.
            guard let allTracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  !allTracks.isEmpty else {
                await MainActor.run { self.audioTracks = [] }
                return
            }

            // Build label list using language metadata from each track.
            var result: [AudioTrack] = []
            for (index, track) in allTracks.enumerated() {
                let rawLang  = (try? await track.load(.languageCode)) ?? ""
                let extTag   = (try? await track.load(.extendedLanguageTag)) ?? ""
                let effective = (rawLang.isEmpty || rawLang == "und") ? extTag : rawLang

                let label: String
                if !effective.isEmpty {
                    label = Locale.current.localizedString(forLanguageCode: effective)
                        ?? effective.uppercased()
                } else {
                    label = "Pista \(index + 1)"
                }
                result.append(AudioTrack(
                    id: index,
                    label: label,
                    language: effective.isEmpty ? nil : effective
                ))
            }

            await MainActor.run {
                // Only show picker when there are genuinely multiple tracks.
                if allTracks.count > 1 {
                    self.audioTracks = result
                } else {
                    self.audioTracks = []
                }
                self.availableTracks.removeAll { $0.kind == .audio }
                self.availableTracks.append(contentsOf: result.map {
                    MediaTrack(
                        id: "audio-\($0.id)",
                        kind: .audio,
                        index: $0.id,
                        label: $0.label,
                        languageCode: $0.language
                    )
                })
                self.selectedAudioTrack = self.availableTracks.first { $0.kind == .audio }
                self.selectedAudioTrackIndex = 0
                // Immediately mute all tracks except the first — fixes double-audio bug.
                self.applyAudioMix(trackIndex: 0, to: item, allTracks: allTracks)
            }
        }
    }

    /// Applies an AVAudioMix that silences every track except `trackIndex`.
    /// This is instant and requires no re-conversion.
    private func applyAudioMix(trackIndex: Int, to item: AVPlayerItem, allTracks: [AVAssetTrack]) {
        let params: [AVAudioMixInputParameters] = allTracks.enumerated().map { index, track in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(index == trackIndex ? 1.0 : 0.0, at: .zero)
            return p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        item.audioMix = mix
    }

    private func findFFmpeg() -> URL? {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func parseFrameRate(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "/")

        if pieces.count == 2,
           let numerator = Double(pieces[0]),
           let denominator = Double(pieces[1]),
           denominator != 0 {
            return numerator / denominator
        }

        return Double(trimmed)
    }

    private func findFFprobe() -> URL? {
        [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func cleanupConvertedVideo() {
        guard let convertedVideoURL else { return }
        try? FileManager.default.removeItem(at: convertedVideoURL)
        self.convertedVideoURL = nil
    }

    private func addTimeObserver() {
        // Keeps sliders, labels, and play state synchronized with AVPlayer playback.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }

                self.currentTime = time.seconds.isFinite ? time.seconds : 0

                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    self.duration = itemDuration
                }

                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

}

enum FPSMode: String, CaseIterable {
    case native = "Native FPS"
    case flux = "Flux"

    var next: FPSMode {
        switch self {
        case .native: .flux
        case .flux: .native
        }
    }

    var isActive: Bool {
        self == .flux
    }

    func renderFramesPerSecond(sourceFrameRate: Double?) -> Int {
        switch self {
        case .native:
            guard let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 else { return 60 }
            return max(1, min(240, Int(sourceFrameRate.rounded())))
        case .flux:
            return 60
        }
    }
}
