import AVFoundation
import CoreVideo
import os

// MARK: - Source Frame (movido a nivel de módulo para compartir entre archivos)

struct SourceVideoFrame: Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
}

// MARK: - Async Frame Buffer (Lock-Free con OSAllocatedUnfairLock)
// Reemplaza a FramePlusFrameBuffer. Sin dispatch_sync, sin bloqueos de hilo.
// El hot path (dequeue) es O(1) y retorna nil si el buffer está vacío.

final class AsyncFrameBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffer: ContiguousArray<SourceVideoFrame>
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = max(3, capacity)
        self.buffer = ContiguousArray(
            repeating: SourceVideoFrame(pixelBuffer: Self.dummyBuffer(), time: .invalid),
            count: self.capacity
        )
    }

    @discardableResult
    func enqueue(_ frame: SourceVideoFrame) -> Bool {
        lock.lock()
        guard count < capacity else { lock.unlock(); return false }
        buffer[writeIndex] = frame
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        lock.unlock()
        return true
    }

    func dequeue() -> SourceVideoFrame? {
        lock.lock()
        guard count > 0 else { lock.unlock(); return nil }
        let frame = buffer[readIndex]
        readIndex = (readIndex + 1) % capacity
        count -= 1
        lock.unlock()
        return frame
    }

    func peekNext() -> SourceVideoFrame? {
        lock.lock()
        guard count >= 2 else { lock.unlock(); return nil }
        let frame = buffer[(readIndex + 1) % capacity]
        lock.unlock()
        return frame
    }

    var availableCount: Int {
        lock.lock()
        let c = count
        lock.unlock()
        return c
    }

    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        count = 0
        lock.unlock()
    }

    private static func dummyBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as CFDictionary, &pb)
        return pb!
    }
}

// MARK: - Frame Prefetcher (Hilo Dedicado de Decodificación)
// Reemplaza el timer sobre DispatchQueue.main.
// Corre en una cola serial con QoS .userInteractive.

final class FramePrefetcher: @unchecked Sendable {
    private let decodeQueue = DispatchQueue(
        label: "com.liquidplayer.decode",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private var timer: DispatchSourceTimer?
    private weak var output: AVPlayerItemVideoOutput?
    private let buffer: AsyncFrameBuffer
    private var isRunning = false

    init(output: AVPlayerItemVideoOutput, buffer: AsyncFrameBuffer) {
        self.output = output
        self.buffer = buffer
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        buffer.reset()

        let t = DispatchSource.makeTimerSource(queue: decodeQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.prefetchOne()
        }
        timer = t
        t.resume()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        buffer.reset()
    }

    private func prefetchOne() {
        guard let output else { return }
        let hostTime = CACurrentMediaTime() + 0.100
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
            return
        }
        buffer.enqueue(SourceVideoFrame(
            pixelBuffer: pixelBuffer,
            time: displayTime.isValid ? displayTime : itemTime
        ))
    }
}
