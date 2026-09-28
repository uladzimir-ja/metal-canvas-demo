import Metal

/// Triple-buffered instance storage: the CPU fills one buffer
/// while the GPU may still be reading the other two from previous frames.
final class StampBufferRing {
    static let maxFramesInFlight = 3 // matches the drawable count

    private let device: MTLDevice
    private var buffers: [MTLBuffer]
    private var index = 0
    // Counts free buffers: wait() takes one, the GPU completion handler returns it.
    private let semaphore = DispatchSemaphore(value: maxFramesInFlight)

    init(device: MTLDevice, initialCapacity: Int = 1024) {
        self.device = device
        buffers = (0..<Self.maxFramesInFlight).map { _ in
            Self.makeBuffer(device: device, capacity: initialCapacity)
        }
    }

    /// Returns a buffer for `count` stamps that the GPU is not using.
    /// Blocks while all buffers are in flight; released when `commandBuffer` completes,
    /// so the command buffer must be committed.
    func acquire(count: Int, for commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        semaphore.wait()
        // Runs on a Metal background thread: capture only the (thread-safe) semaphore.
        let semaphore = semaphore
        commandBuffer.addCompletedHandler { @Sendable _ in
            semaphore.signal()
        }

        index = (index + 1) % buffers.count
        let needed = count * MemoryLayout<StampInstance>.stride
        if buffers[index].length < needed {
            // Only this buffer is free right now; the others may still be read by the GPU.
            let capacity = max(count, 2 * buffers[index].length / MemoryLayout<StampInstance>.stride)
            buffers[index] = Self.makeBuffer(device: device, capacity: capacity)
            print("Stamp buffer \(index) grown to \(capacity) stamps")
        }
        return buffers[index]
    }

    private static func makeBuffer(device: MTLDevice, capacity: Int) -> MTLBuffer {
        // Shared storage: CPU writes, GPU reads the same memory, no copy.
        guard let buffer = device.makeBuffer(length: capacity * MemoryLayout<StampInstance>.stride,
                                             options: .storageModeShared) else {
            fatalError("Cannot allocate stamp buffer")
        }
        buffer.label = "Stamp instances"
        return buffer
    }
}
