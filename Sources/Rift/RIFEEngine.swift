import Accelerate
import CoreML
import CoreVideo
import Foundation
import OSLog
import QuartzCore

extension CVBuffer: @retroactive @unchecked Sendable {}

enum RIFEError: Error, LocalizedError {
    case modelLoad(String)
    case inference(String)
    case resolution(String)
    case timeout
    case pixelBuffer(String)

    var errorDescription: String? {
        switch self {
        case .modelLoad(let message): "RIFE model load failed: \(message)"
        case .inference(let message): "RIFE inference failed: \(message)"
        case .resolution(let message): "RIFE resolution error: \(message)"
        case .timeout: "RIFE inference timed out"
        case .pixelBuffer(let message): "RIFE pixel buffer error: \(message)"
        }
    }
}

actor RIFEEngine {
    struct Metrics {
        var lastLatencyMS: Double = 0
        var p50LatencyMS: Double = 0
        var p95LatencyMS: Double = 0
        var p99LatencyMS: Double = 0
        var inferenceCount: Int = 0
    }

    nonisolated(unsafe) private let model: MLModel
    nonisolated(unsafe) private let options = MLPredictionOptions()
    private let inputFrame0Name: String
    private let inputFrame1Name: String
    private let timestepName: String
    private let outputName: String
    private let signposter = OSSignposter(subsystem: "Rift", category: "RIFE")
    private let preallocatedTimestepArray: MLMultiArray
    private let cachedTimestepFeature: MLFeatureValue
    private var outputPool: CVPixelBufferPool?
    private var outputPoolWidth = 0
    private var outputPoolHeight = 0
    private var paddingPool: CVPixelBufferPool?
    private var paddingPoolWidth = 0
    private var paddingPoolHeight = 0
    private var latencySamples: [Double] = []
    private var sortedLatencySamples: [Double] = []
    private var currentTimestep: Float = .nan
    private var maxWidth: Int
    private var maxHeight: Int

    init(modelURL: URL, computeUnits: MLComputeUnits = .all) async throws {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let loadURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                loadURL = modelURL
            } else {
                loadURL = try await MLModel.compileModel(at: modelURL)
            }
            model = try MLModel(contentsOf: loadURL, configuration: configuration)
        } catch {
            throw RIFEError.modelLoad(error.localizedDescription)
        }

        do {
            preallocatedTimestepArray = try MLMultiArray(shape: [1], dataType: .float32)
            cachedTimestepFeature = MLFeatureValue(multiArray: preallocatedTimestepArray)
        } catch {
            throw RIFEError.modelLoad("Could not allocate timestep input: \(error.localizedDescription)")
        }

        let description = model.modelDescription
        let inputNames = Array(description.inputDescriptionsByName.keys)
        let outputNames = Array(description.outputDescriptionsByName.keys)

        guard let frame0 = Self.preferredName(from: inputNames, candidates: ["frame0", "img0", "I0", "x0"]),
              let frame1 = Self.preferredName(from: inputNames, candidates: ["frame1", "img1", "I1", "x1"]),
              let timestep = Self.preferredName(from: inputNames, candidates: ["timestep", "t", "time"]),
              let output = Self.preferredName(from: outputNames, candidates: ["interpolated", "output", "y", "imgt"]) ?? outputNames.first else {
            throw RIFEError.modelLoad("Could not infer frame/timestep/output feature names")
        }

        inputFrame0Name = frame0
        inputFrame1Name = frame1
        timestepName = timestep
        outputName = output

        let inferredSize = Self.inferInputSize(description: description, frameInputName: frame0)
        maxWidth = inferredSize.width
        maxHeight = inferredSize.height

        try await warmUp()
    }

    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer, timestep: Float = 0.5) async throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        guard width == CVPixelBufferGetWidth(frame1),
              height == CVPixelBufferGetHeight(frame1) else {
            throw RIFEError.resolution("Input frame sizes differ")
        }

        guard width <= maxWidth, height <= maxHeight else {
            throw RIFEError.resolution("Input \(width)x\(height) exceeds model \(maxWidth)x\(maxHeight)")
        }

        let paddedWidth = max(Self.roundUpToMultipleOf32(width), maxWidth)
        let paddedHeight = max(Self.roundUpToMultipleOf32(height), maxHeight)
        let paddedFrame0 = try paddedPixelBufferIfNeeded(frame0, width: paddedWidth, height: paddedHeight)
        let paddedFrame1 = try paddedPixelBufferIfNeeded(frame1, width: paddedWidth, height: paddedHeight)
        let timestepFeature = try featureValue(for: timestep)
        let provider = RIFEInputFeatureProvider(
            frame0Name: inputFrame0Name,
            frame1Name: inputFrame1Name,
            timestepName: timestepName,
            frame0: paddedFrame0,
            frame1: paddedFrame1,
            timestep: timestepFeature
        )

        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("RIFE inference", id: signpostID)
        let start = CACurrentMediaTime()
        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider, options: options)
        } catch {
            signposter.endInterval("RIFE inference", state)
            throw RIFEError.inference(error.localizedDescription)
        }
        signposter.endInterval("RIFE inference", state)
        recordLatency((CACurrentMediaTime() - start) * 1000)

        guard let outputFeature = prediction.featureValue(for: outputName) else {
            throw RIFEError.inference("Missing output feature \(outputName)")
        }

        let output = try pixelBuffer(from: outputFeature, width: paddedWidth, height: paddedHeight)
        if paddedWidth == width, paddedHeight == height {
            return output
        }

        return try croppedPixelBuffer(output, width: width, height: height)
    }

    func metrics() -> Metrics {
        var metrics = Metrics()
        metrics.inferenceCount = latencySamples.count
        metrics.lastLatencyMS = latencySamples.last ?? 0
        metrics.p50LatencyMS = percentile(0.50)
        metrics.p95LatencyMS = percentile(0.95)
        metrics.p99LatencyMS = percentile(0.99)
        return metrics
    }

    private func warmUp() async throws {
        let width = min(maxWidth, 1280)
        let height = min(maxHeight, 720)
        try initializeOutputPool(width: width, height: height, minimumBufferCount: 4)
        try initializePaddingPool(width: Self.roundUpToMultipleOf32(width), height: Self.roundUpToMultipleOf32(height), minimumBufferCount: 4)
        let frame0 = try Self.makeBlackPixelBuffer(width: width, height: height)
        let frame1 = try Self.makeBlackPixelBuffer(width: width, height: height)
        _ = try await interpolate(frame0: frame0, frame1: frame1, timestep: 0.5)
        latencySamples.removeAll(keepingCapacity: true)
        sortedLatencySamples.removeAll(keepingCapacity: true)
    }

    private func featureValue(for timestep: Float) throws -> MLFeatureValue {
        if timestep != currentTimestep {
            preallocatedTimestepArray[0] = NSNumber(value: timestep)
            currentTimestep = timestep
        }

        return cachedTimestepFeature
    }

    private func pixelBuffer(from feature: MLFeatureValue, width: Int, height: Int) throws -> CVPixelBuffer {
        if let pixelBuffer = feature.imageBufferValue {
            return pixelBuffer
        }

        guard let array = feature.multiArrayValue else {
            throw RIFEError.inference("Output is neither image nor MLMultiArray")
        }

        let output = try dequeueOutputBuffer(width: width, height: height)
        try Self.copyMultiArrayRGBToBGRA(array, pixelBuffer: output)
        return output
    }

    private func dequeueOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPool == nil || outputPoolWidth != width || outputPoolHeight != height {
            try initializeOutputPool(width: width, height: height, minimumBufferCount: 4)
        }

        return try dequeue(from: outputPool, width: width, height: height, fallbackPixelFormat: kCVPixelFormatType_32BGRA)
    }

    private func dequeuePaddingBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if paddingPool == nil || paddingPoolWidth != width || paddingPoolHeight != height {
            try initializePaddingPool(width: width, height: height, minimumBufferCount: 4)
        }

        return try dequeue(from: paddingPool, width: width, height: height, fallbackPixelFormat: kCVPixelFormatType_32BGRA)
    }

    private func initializeOutputPool(width: Int, height: Int, minimumBufferCount: Int) throws {
        outputPool = try Self.makePixelBufferPool(width: width, height: height, minimumBufferCount: minimumBufferCount)
        outputPoolWidth = width
        outputPoolHeight = height
    }

    private func initializePaddingPool(width: Int, height: Int, minimumBufferCount: Int) throws {
        paddingPool = try Self.makePixelBufferPool(width: width, height: height, minimumBufferCount: minimumBufferCount)
        paddingPoolWidth = width
        paddingPoolHeight = height
    }

    private func dequeue(
        from pool: CVPixelBufferPool?,
        width: Int,
        height: Int,
        fallbackPixelFormat: OSType
    ) throws -> CVPixelBuffer {
        if let pool {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            if status == kCVReturnSuccess, let pixelBuffer {
                return pixelBuffer
            }
        }

        return try Self.makePixelBuffer(width: width, height: height, pixelFormat: fallbackPixelFormat)
    }

    private func paddedPixelBufferIfNeeded(_ input: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let inputWidth = CVPixelBufferGetWidth(input)
        let inputHeight = CVPixelBufferGetHeight(input)
        guard inputWidth != width || inputHeight != height else { return input }

        let output = try dequeuePaddingBuffer(width: width, height: height)
        try Self.copyRect(input, to: output, width: inputWidth, height: inputHeight, clearDestination: true)
        return output
    }

    private func croppedPixelBuffer(_ input: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let output = try dequeuePaddingBuffer(width: width, height: height)
        try Self.copyRect(input, to: output, width: width, height: height, clearDestination: false)
        return output
    }

    private func recordLatency(_ latency: Double) {
        latencySamples.append(latency)
        let insertionIndex = sortedInsertionIndex(for: latency)
        sortedLatencySamples.insert(latency, at: insertionIndex)

        if latencySamples.count > 2048, let removed = latencySamples.first {
            latencySamples.removeFirst()
            if let index = sortedLatencySamples.firstIndex(of: removed) {
                sortedLatencySamples.remove(at: index)
            }
        }
    }

    private func percentile(_ percentile: Double) -> Double {
        guard !sortedLatencySamples.isEmpty else { return 0 }
        let index = min(sortedLatencySamples.count - 1, max(0, Int(Double(sortedLatencySamples.count - 1) * percentile)))
        return sortedLatencySamples[index]
    }

    private func sortedInsertionIndex(for latency: Double) -> Int {
        var low = 0
        var high = sortedLatencySamples.count
        while low < high {
            let mid = (low + high) / 2
            if sortedLatencySamples[mid] < latency {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func preferredName(from names: [String], candidates: [String]) -> String? {
        for candidate in candidates {
            if let exact = names.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return exact
            }
        }

        return names.first
    }

    private static func inferInputSize(description: MLModelDescription, frameInputName: String) -> (width: Int, height: Int) {
        let input = description.inputDescriptionsByName[frameInputName]
        if let constraint = input?.imageConstraint {
            return (constraint.pixelsWide, constraint.pixelsHigh)
        }

        if let shape = input?.multiArrayConstraint?.shape.map(\.intValue), shape.count >= 4 {
            return (shape[3], shape[2])
        }

        return (1280, 720)
    }

    private static func roundUpToMultipleOf32(_ value: Int) -> Int {
        ((value + 31) / 32) * 32
    }

    private static func makeBlackPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func makePixelBufferPool(width: Int, height: Int, minimumBufferCount: Int) throws -> CVPixelBufferPool {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw RIFEError.pixelBuffer("CVPixelBufferPoolCreate failed with \(status)")
        }

        var warmed: [CVPixelBuffer] = []
        warmed.reserveCapacity(minimumBufferCount)
        for _ in 0..<minimumBufferCount {
            var buffer: CVPixelBuffer?
            let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard createStatus == kCVReturnSuccess, let buffer else {
                throw RIFEError.pixelBuffer("CVPixelBufferPoolCreatePixelBuffer failed with \(createStatus)")
            }
            warmed.append(buffer)
        }

        return pool
    }

    private static func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw RIFEError.pixelBuffer("CVPixelBufferCreate failed with \(result)")
        }

        return pixelBuffer
    }

    private static func copyRect(
        _ input: CVPixelBuffer,
        to output: CVPixelBuffer,
        width: Int,
        height: Int,
        clearDestination: Bool
    ) throws {
        CVPixelBufferLockBaseAddress(input, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(input, .readOnly)
        }

        guard let src = CVPixelBufferGetBaseAddress(input),
              let dst = CVPixelBufferGetBaseAddress(output) else {
            throw RIFEError.pixelBuffer("Could not lock pixel buffers")
        }

        let srcStride = CVPixelBufferGetBytesPerRow(input)
        let dstStride = CVPixelBufferGetBytesPerRow(output)
        if clearDestination {
            memset(dst, 0, CVPixelBufferGetDataSize(output))
        }
        for row in 0..<height {
            memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), width * 4)
        }
    }

    private static func copyMultiArrayRGBToBGRA(_ array: MLMultiArray, pixelBuffer: CVPixelBuffer) throws {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4 else {
            throw RIFEError.inference("Expected rank-4 RGB output, got shape \(shape)")
        }

        let channelFirst = shape[1] == 3
        let height = channelFirst ? shape[2] : shape[1]
        let width = channelFirst ? shape[3] : shape[2]
        guard width == CVPixelBufferGetWidth(pixelBuffer), height == CVPixelBufferGetHeight(pixelBuffer) else {
            throw RIFEError.resolution("Output shape \(shape) does not match pixel buffer")
        }

        let count = width * height
        let strides = array.strides.map(\.intValue)
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)

        switch array.dataType {
        case .float32:
            let data = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 0, width: width, height: height, destination: &red)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 1, width: width, height: height, destination: &green)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 2, width: width, height: height, destination: &blue)
        case .float16:
            let data = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 0, width: width, height: height, destination: &red)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 1, width: width, height: height, destination: &green)
            copyChannel(data, strides: strides, channelFirst: channelFirst, channel: 2, width: width, height: height, destination: &blue)
        default:
            throw RIFEError.inference("Unsupported output MLMultiArray type \(array.dataType)")
        }

        var scale: Float = 255
        var red8 = [UInt8](repeating: 0, count: count)
        var green8 = [UInt8](repeating: 0, count: count)
        var blue8 = [UInt8](repeating: 0, count: count)
        var alpha8 = [UInt8](repeating: 255, count: count)

        red.withUnsafeBufferPointer { src in
            var scaled = [Float](repeating: 0, count: count)
            scaled.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vclip(dst.baseAddress!, 1, [0], [255], dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vfixu8(dst.baseAddress!, 1, &red8, 1, vDSP_Length(count))
            }
        }
        green.withUnsafeBufferPointer { src in
            var scaled = [Float](repeating: 0, count: count)
            scaled.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vclip(dst.baseAddress!, 1, [0], [255], dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vfixu8(dst.baseAddress!, 1, &green8, 1, vDSP_Length(count))
            }
        }
        blue.withUnsafeBufferPointer { src in
            var scaled = [Float](repeating: 0, count: count)
            scaled.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vclip(dst.baseAddress!, 1, [0], [255], dst.baseAddress!, 1, vDSP_Length(count))
                vDSP_vfixu8(dst.baseAddress!, 1, &blue8, 1, vDSP_Length(count))
            }
        }

        try alpha8.withUnsafeMutableBytes { alphaBytes in
            try red8.withUnsafeMutableBytes { redBytes in
                try green8.withUnsafeMutableBytes { greenBytes in
                    try blue8.withUnsafeMutableBytes { blueBytes in
                        CVPixelBufferLockBaseAddress(pixelBuffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                            throw RIFEError.pixelBuffer("Could not lock output pixel buffer")
                        }

                        var alphaPlane = vImage_Buffer(data: alphaBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        var redPlane = vImage_Buffer(data: redBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        var greenPlane = vImage_Buffer(data: greenBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        var bluePlane = vImage_Buffer(data: blueBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                        var destination = vImage_Buffer(
                            data: base,
                            height: vImagePixelCount(height),
                            width: vImagePixelCount(width),
                            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
                        )

                        let result = vImageConvert_Planar8toARGB8888(
                            &alphaPlane,
                            &redPlane,
                            &greenPlane,
                            &bluePlane,
                            &destination,
                            vImage_Flags(kvImageNoFlags)
                        )
                        guard result == kvImageNoError else {
                            throw RIFEError.pixelBuffer("vImageConvert_Planar8toARGB8888 failed with \(result)")
                        }
                    }
                }
            }
        }
    }

    private static func copyChannel(
        _ data: UnsafePointer<Float>,
        strides: [Int],
        channelFirst: Bool,
        channel: Int,
        width: Int,
        height: Int,
        destination: inout [Float]
    ) {
        if channelFirst, strides[2] == width, strides[3] == 1 {
            let offset = channel * strides[1]
            destination.withUnsafeMutableBufferPointer { dst in
                cblas_scopy(Int32(width * height), data.advanced(by: offset), 1, dst.baseAddress!, 1)
            }
            return
        }

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = channelFirst
                    ? channel * strides[1] + y * strides[2] + x * strides[3]
                    : y * strides[1] + x * strides[2] + channel * strides[3]
                destination[y * width + x] = data[sourceIndex]
            }
        }
    }

    private static func copyChannel(
        _ data: UnsafePointer<Float16>,
        strides: [Int],
        channelFirst: Bool,
        channel: Int,
        width: Int,
        height: Int,
        destination: inout [Float]
    ) {
        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = channelFirst
                    ? channel * strides[1] + y * strides[2] + x * strides[3]
                    : y * strides[1] + x * strides[2] + channel * strides[3]
                destination[y * width + x] = Float(data[sourceIndex])
            }
        }
    }
}

private final class RIFEInputFeatureProvider: MLFeatureProvider, @unchecked Sendable {
    let frame0Name: String
    let frame1Name: String
    let timestepName: String
    let frame0: CVPixelBuffer
    let frame1: CVPixelBuffer
    let timestep: MLFeatureValue

    var featureNames: Set<String> {
        [frame0Name, frame1Name, timestepName]
    }

    init(
        frame0Name: String,
        frame1Name: String,
        timestepName: String,
        frame0: CVPixelBuffer,
        frame1: CVPixelBuffer,
        timestep: MLFeatureValue
    ) {
        self.frame0Name = frame0Name
        self.frame1Name = frame1Name
        self.timestepName = timestepName
        self.frame0 = frame0
        self.frame1 = frame1
        self.timestep = timestep
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == frame0Name {
            return MLFeatureValue(pixelBuffer: frame0)
        }

        if featureName == frame1Name {
            return MLFeatureValue(pixelBuffer: frame1)
        }

        if featureName == timestepName {
            return timestep
        }

        return nil
    }
}
