@preconcurrency import AVFoundation
import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Metal
import QuartzCore

enum PlaceboRendererError: Error {
    case metal(String)
    case render(String)
}

final class PlaceboRenderer: @unchecked Sendable {
    struct Config: Sendable {
        var upscaler: Upscaler = .ewa_lanczos
        var downscaler: Downscaler = .hermite
        var deband: Bool = true
        var debandIterations: Int = 4
        var hdrToneMapping: ToneMappingAlgorithm = .bt2446a
        var hdrPeakDetection: Bool = true
        var colorManagement: Bool = true
        var targetColorSpace: TargetColorSpace = .auto

        enum Upscaler: Sendable {
            case bilinear
            case lanczos
            case ewa_lanczos
            case jinc
            case nearest
        }

        enum Downscaler: Sendable {
            case bilinear
            case hermite
            case lanczos
        }

        enum ToneMappingAlgorithm: Sendable {
            case bt2446a
            case hable
            case reinhard
            case clip
        }

        enum TargetColorSpace: Sendable {
            case auto
            case sdr
            case hdr10
            case p3
        }
    }

    private let device: MTLDevice
    private let ciContext: CIContext
    private var config: Config
    private(set) var isUsingFallback = true

    init(device: MTLDevice, config: Config) throws {
        self.device = device
        self.config = config
        self.ciContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any
            ]
        )
    }

    func process(
        frame: CVPixelBuffer,
        hdrMetadata: HDRMetadata?,
        targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let sourceImage = CIImage(cvPixelBuffer: frame)
        let fittedImage = imageByFitting(sourceImage, into: targetTexture)
        let processed = applyFallbackPicturePasses(fittedImage, hdrMetadata: hdrMetadata)

        ciContext.render(
            processed,
            to: targetTexture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: targetTexture.width, height: targetTexture.height),
            colorSpace: targetColorSpace(hdrMetadata: hdrMetadata)
        )
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    private func imageByFitting(_ image: CIImage, into texture: MTLTexture) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let targetSize = CGSize(width: texture.width, height: texture.height)
        let scale = min(targetSize.width / image.extent.width, targetSize.height / image.extent.height)
        let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let offset = CGPoint(
            x: (targetSize.width - scaledSize.width) * 0.5,
            y: (targetSize.height - scaledSize.height) * 0.5
        )

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .cropped(to: CGRect(origin: .zero, size: targetSize))
    }

    private func applyFallbackPicturePasses(_ image: CIImage, hdrMetadata: HDRMetadata?) -> CIImage {
        var output = image

        if config.deband {
            let radius = min(max(Double(config.debandIterations), 1), 6)
            output = output
                .applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.018 * radius,
                    "inputSharpness": 0.38
                ])
                .cropped(to: image.extent)
        }

        if hdrMetadata != nil, config.hdrToneMapping != .clip {
            output = output
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 0.72,
                    "inputShadowAmount": 0.08
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: config.targetColorSpace == .sdr ? 0.96 : 1.0,
                    kCIInputContrastKey: 1.02
                ])
                .cropped(to: image.extent)
        }

        if config.upscaler == .lanczos || config.upscaler == .ewa_lanczos || config.upscaler == .jinc {
            output = output
                .applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: config.upscaler == .jinc ? 0.28 : 0.18
                ])
                .cropped(to: image.extent)
        }

        return output
    }

    private func targetColorSpace(hdrMetadata: HDRMetadata?) -> CGColorSpace {
        switch config.targetColorSpace {
        case .auto:
            if hdrMetadata != nil, let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
                return p3
            }
            return CGColorSpaceCreateDeviceRGB()
        case .sdr:
            return CGColorSpaceCreateDeviceRGB()
        case .hdr10:
            return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ?? CGColorSpaceCreateDeviceRGB()
        case .p3:
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
    }
}
