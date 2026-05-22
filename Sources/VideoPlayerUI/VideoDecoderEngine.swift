@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import KSPlayer

struct MediaTrack: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case video
        case audio
        case subtitle
    }

    let id: String
    let kind: Kind
    let index: Int
    let label: String
    let languageCode: String?
}

struct HDRMetadata: Sendable {
    let transfer: CFString
    let colorPrimaries: CFString
    let maxLuminance: Float?
    let minLuminance: Float?
    let contentLightLevel: (maxCLL: Float, maxFALL: Float)?
}

struct DecodedFrame: Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
    let hdrMetadata: HDRMetadata?
}

enum VideoDecoderEngineError: Error {
    case asset(String)
    case reader(String)
    case endOfStream
}

actor VideoDecoderEngine {
    private let url: URL
    private let asset: AVURLAsset
    private let options: KSOptions
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var mediaTracks: [MediaTrack] = []
    private var estimatedFrameDuration = CMTime(value: 1, timescale: 24)
    private var lastTime: CMTime = .zero
    private(set) var duration: CMTime

    var currentTime: CMTime {
        get async { lastTime }
    }

    init(url: URL, options: KSOptions = KSOptions()) async throws {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.options = options
        self.duration = .zero

        let loadedDuration = try await asset.load(.duration)
        self.duration = loadedDuration
        self.mediaTracks = try await Self.loadTracks(from: asset)
        try await configureReader(startingAt: .zero)
    }

    func nextFrame() async throws -> DecodedFrame {
        guard let output = videoOutput else {
            throw VideoDecoderEngineError.reader("Video output is not configured")
        }

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            if reader?.status == .failed {
                throw VideoDecoderEngineError.reader(reader?.error?.localizedDescription ?? "Reader failed")
            }
            throw VideoDecoderEngineError.endOfStream
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw VideoDecoderEngineError.reader("Sample did not contain a pixel buffer")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        let frameDuration = sampleDuration.isValid && sampleDuration.seconds > 0 ? sampleDuration : estimatedFrameDuration

        if lastTime.isValid, pts.isValid {
            let delta = CMTimeSubtract(pts, lastTime)
            if delta.seconds.isFinite, delta.seconds > 0, delta.seconds < 0.25 {
                estimatedFrameDuration = delta
            }
        }
        lastTime = pts

        return DecodedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: pts,
            duration: frameDuration,
            hdrMetadata: Self.hdrMetadata(from: pixelBuffer)
        )
    }

    func seek(to time: CMTime) async throws {
        reader?.cancelReading()
        reader = nil
        videoOutput = nil
        lastTime = time
        try await configureReader(startingAt: time)
    }

    func tracks() -> [MediaTrack] {
        mediaTracks
    }

    func selectTrack(_ track: MediaTrack) async {
        switch track.kind {
        case .video:
            break
        case .audio:
            break
        case .subtitle:
            break
        }
    }

    private func configureReader(startingAt time: CMTime) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDecoderEngineError.asset("No video track")
        }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        if nominalFrameRate > 0 {
            estimatedFrameDuration = CMTime(seconds: 1.0 / Double(nominalFrameRate), preferredTimescale: 60_000)
        }

        let reader = try AVAssetReader(asset: asset)
        if time > .zero {
            reader.timeRange = CMTimeRange(start: time, duration: CMTimeSubtract(duration, time))
        }

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw VideoDecoderEngineError.reader("Cannot add video output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw VideoDecoderEngineError.reader(reader.error?.localizedDescription ?? "Reader did not start")
        }

        self.reader = reader
        self.videoOutput = output
    }

    private static func loadTracks(from asset: AVAsset) async throws -> [MediaTrack] {
        var result: [MediaTrack] = []

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        for (index, track) in videoTracks.enumerated() {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            result.append(MediaTrack(
                id: "video-\(index)",
                kind: .video,
                index: index,
                label: size == .zero ? "Video \(index + 1)" : "Video \(Int(size.width))x\(Int(size.height))",
                languageCode: nil
            ))
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for (index, track) in audioTracks.enumerated() {
            let extendedLanguage = try? await track.load(.extendedLanguageTag)
            let languageCode = try? await track.load(.languageCode)
            let language = extendedLanguage ?? languageCode
            result.append(MediaTrack(
                id: "audio-\(index)",
                kind: .audio,
                index: index,
                label: localizedTrackLabel(prefix: "Audio", index: index, language: language),
                languageCode: language
            ))
        }

        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        for (index, track) in subtitleTracks.enumerated() {
            let extendedLanguage = try? await track.load(.extendedLanguageTag)
            let languageCode = try? await track.load(.languageCode)
            let language = extendedLanguage ?? languageCode
            result.append(MediaTrack(
                id: "subtitle-\(index)",
                kind: .subtitle,
                index: index,
                label: localizedTrackLabel(prefix: "Subtitulo", index: index, language: language),
                languageCode: language
            ))
        }

        return result
    }

    private static func localizedTrackLabel(prefix: String, index: Int, language: String?) -> String {
        guard let language, !language.isEmpty, language != "und" else {
            return "\(prefix) \(index + 1)"
        }
        let localized = Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()
        return "\(prefix) \(index + 1) · \(localized)"
    }

    private static func hdrMetadata(from pixelBuffer: CVPixelBuffer) -> HDRMetadata? {
        guard let transferValue = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
              let primariesValue = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) else {
            return nil
        }

        let transfer = transferValue as! CFString
        let primaries = primariesValue as! CFString

        return HDRMetadata(
            transfer: transfer,
            colorPrimaries: primaries,
            maxLuminance: nil,
            minLuminance: nil,
            contentLightLevel: nil
        )
    }
}
