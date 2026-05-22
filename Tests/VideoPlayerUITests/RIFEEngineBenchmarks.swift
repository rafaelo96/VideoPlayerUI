import CoreVideo
import Darwin
import XCTest
@testable import VideoPlayerUI

final class RIFEEngineBenchmarks: XCTestCase {
    struct BenchmarkResult {
        let resolution: String
        let p50: Double
        let p95: Double
        let p99: Double
        let throughput: Double
        let peakMemoryMB: Double
        let chipTemperatureC: Double?
    }

    func testRIFELatencyMatrix() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["RIFE_MODEL_URL"] else {
            throw XCTSkip("Set RIFE_MODEL_URL=/path/to/RIFE.mlpackage to run RIFE benchmarks")
        }

        let engine = try await RIFEEngine(modelURL: URL(fileURLWithPath: modelPath), computeUnits: .all)
        let resolutions = [
            (640, 360, "360p"),
            (854, 480, "480p"),
            (1280, 720, "720p"),
            (1920, 1080, "1080p"),
            (3840, 2160, "4K")
        ]

        var results: [BenchmarkResult] = []
        for (width, height, label) in resolutions {
            let frame0 = try makePatternPixelBuffer(width: width, height: height, phase: 0)
            let frame1 = try makePatternPixelBuffer(width: width, height: height, phase: 9)
            var latencies: [Double] = []
            let startMemory = currentResidentMemoryMB()

            for _ in 0..<8 {
                _ = try? await engine.interpolate(frame0: frame0, frame1: frame1, timestep: 0.5)
            }

            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < 10 {
                let tick = CACurrentMediaTime()
                _ = try await engine.interpolate(frame0: frame0, frame1: frame1, timestep: 0.5)
                latencies.append((CACurrentMediaTime() - tick) * 1000)
            }

            let elapsed = CACurrentMediaTime() - start
            let sorted = latencies.sorted()
            let result = BenchmarkResult(
                resolution: label,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                p99: percentile(sorted, 0.99),
                throughput: Double(latencies.count) / elapsed,
                peakMemoryMB: max(startMemory, currentResidentMemoryMB()),
                chipTemperatureC: readAppleSiliconTemperatureC()
            )
            results.append(result)
        }

        for result in results {
            print(
                """
                RIFE \(result.resolution): \
                p50=\(String(format: "%.2f", result.p50))ms \
                p95=\(String(format: "%.2f", result.p95))ms \
                p99=\(String(format: "%.2f", result.p99))ms \
                throughput=\(String(format: "%.2f", result.throughput))fps \
                rss=\(String(format: "%.1f", result.peakMemoryMB))MB \
                temp=\(result.chipTemperatureC.map { String(format: "%.1fC", $0) } ?? "unavailable")
                """
            )
        }
    }

    func testPSNRAndSSIMHelpers() throws {
        let a = [Float](repeating: 0.5, count: 256)
        let b = [Float](repeating: 0.5, count: 256)
        XCTAssertGreaterThan(psnr(a, b), 90)
        XCTAssertEqual(ssim(a, b), 1.0, accuracy: 0.0001)
    }

    private func makePatternPixelBuffer(width: Int, height: Int, phase: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "RIFEBenchmark", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                base[offset + 0] = UInt8((x + phase) & 0xff)
                base[offset + 1] = UInt8((y + phase) & 0xff)
                base[offset + 2] = UInt8((x + y + phase) & 0xff)
                base[offset + 3] = 255
            }
        }

        return pixelBuffer
    }

    private func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return sorted[index]
    }

    private func currentResidentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    private func readAppleSiliconTemperatureC() -> Double? {
        nil
    }

    private func psnr(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let mse = zip(a, b).reduce(0.0) { partial, pair in
            let diff = Double(pair.0 - pair.1)
            return partial + diff * diff
        } / Double(a.count)
        if mse == 0 { return 100 }
        return 20 * log10(1.0 / sqrt(mse))
    }

    private func ssim(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var varianceA: Float = 0
        var varianceB: Float = 0
        var covariance: Float = 0
        for index in a.indices {
            let da = a[index] - meanA
            let db = b[index] - meanB
            varianceA += da * da
            varianceB += db * db
            covariance += da * db
        }
        varianceA /= Float(a.count)
        varianceB /= Float(a.count)
        covariance /= Float(a.count)

        let c1: Float = 0.01 * 0.01
        let c2: Float = 0.03 * 0.03
        let numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2)
        let denominator = (meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2)
        return Double(numerator / denominator)
    }
}
