import Foundation

/// Per-stroke diagnostics: GPU work, frame pacing and touch-to-glass latency.
struct StrokeStats {
    var stamps = 0
    var drawCalls = 0
    private var encodeTime: TimeInterval = 0
    private var encodedFrames = 0
    private var frameIntervals = Summary()
    private var latencies = Summary()

    mutating func addEncode(time: TimeInterval, drawCalls: Int) {
        encodeTime += time
        encodedFrames += 1
        self.drawCalls += drawCalls
    }

    mutating func addFrameInterval(_ interval: TimeInterval) {
        frameIntervals.add(interval)
    }

    mutating func addLatency(_ latency: TimeInterval) {
        latencies.add(latency)
    }

    var report: String {
        let encode = encodedFrames > 0 ? encodeTime / Double(encodedFrames) : 0
        return String(format: "Stroke stamps: %d, draw calls: %d, stamp encode %.3f ms/frame\n", stamps, drawCalls, encode * 1000)
            + String(format: "  frames: %d, interval avg %.1f ms (%.0f Hz), max %.1f ms\n",
                     frameIntervals.count, frameIntervals.average * 1000,
                     frameIntervals.average > 0 ? 1 / frameIntervals.average : 0, frameIntervals.max * 1000)
            + String(format: "  %@: avg %.1f ms, max %.1f ms (%d frames)", Self.latencyLabel,
                     latencies.average * 1000, latencies.max * 1000, latencies.count)
    }

    #if targetEnvironment(simulator)
    private static let latencyLabel = "touch -> GPU done (simulator, no display time)"
    #else
    private static let latencyLabel = "touch -> glass"
    #endif

    private struct Summary {
        private(set) var count = 0
        private var sum: TimeInterval = 0
        private(set) var max: TimeInterval = 0

        var average: TimeInterval { count > 0 ? sum / Double(count) : 0 }

        mutating func add(_ value: TimeInterval) {
            count += 1
            sum += value
            max = Swift.max(max, value)
        }
    }
}
