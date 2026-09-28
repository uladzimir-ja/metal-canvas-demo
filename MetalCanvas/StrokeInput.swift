import UIKit

protocol StrokeInputDelegate: AnyObject {
    func strokeInputDidBegin(_ input: StrokeInput)
    /// Samples whose properties are final, in stroke order: safe to draw permanently.
    func strokeInput(_ input: StrokeInput, didCommit samples: [InputSample])
    /// Replaces the provisional tail: real samples still waiting for Pencil updates, then predicted ones.
    func strokeInput(_ input: StrokeInput, didUpdateTail pending: [InputSample], predicted: [InputSample])
    func strokeInputDidEnd(_ input: StrokeInput)
    func strokeInputDidCancel(_ input: StrokeInput)
}

/// Turns UITouch events into InputSamples in canvas space, one stroke at a time.
///
/// Pencil reports force and tilt as estimates first and sends the real values later
/// (touchesEstimatedPropertiesUpdated). Only a contiguous prefix of final samples is committed;
/// samples still waiting for updates stay in the tail, which is redrawn every frame.
final class StrokeInput {
    /// Debug: treat finger/mouse samples as estimated and deliver a fake update (lighter force)
    /// a bit later, to exercise the update path without a Pencil.
    private static let simulateEstimatedUpdates = false
    private static let simulatedUpdateDelay: Duration = .milliseconds(30)
    /// After lift-off, wait this long for outstanding Pencil updates, then keep the estimates.
    private static let updateTimeout: Duration = .milliseconds(150)

    weak var delegate: StrokeInputDelegate?

    // Pressure emulation for touches without force (finger, simulator mouse): faster = lighter.
    private let fullPressureSpeed: Float = 100  // pt/s and slower -> pressure 1
    private let minPressureSpeed: Float = 2000  // pt/s and faster -> minEmulatedPressure
    private let minEmulatedPressure: Float = 0.3
    private let pressureSmoothing: Float = 0.7  // weight of the previous value, removes jitter

    private var activeTouch: UITouch?
    private var strokeGeneration = 0 // guards delayed work against a newer stroke
    private var strokeStartTime: TimeInterval = 0
    private var hasPreviousSample = false
    private var lastViewPosition = SIMD2<Float>.zero
    /// Absolute time of the newest real sample (seconds since boot, same clock as frame presentation).
    private(set) var lastTimestamp: TimeInterval = 0
    private var emulatedPressure: Float = 1

    // The open stroke: every real sample, and which of them are final.
    private var isStrokeOpen = false
    private var isAwaitingEnd = false // lifted off, waiting for the last updates
    private var samples: [InputSample] = []
    private var isFinal: [Bool] = []
    private var committedCount = 0
    private var pendingUpdates: [Int: Int] = [:] // estimationUpdateIndex -> sample index
    private var predicted: [InputSample] = []
    private var nextSimulatedIndex = 0

    // Diagnostics.
    private var eventCount = 0
    private var predictedSampleCount = 0
    private var estimates: [Int: (force: Float, time: TimeInterval)] = [:] // sample index -> first estimate
    private var updatedCount = 0
    private var updateDelaySum: TimeInterval = 0
    private var forceChangeSum: Float = 0
    private var forceChangeMax: Float = 0
    private var timedOutCount = 0

    // MARK: - Touches

    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView, layout: CanvasLayout) {
        // The previous stroke still waits for updates: close it with what it has.
        if isAwaitingEnd {
            finishWithEstimates()
        }
        // One stroke at a time: extra fingers are ignored.
        guard activeTouch == nil, let touch = touches.first else { return }
        startStroke(touch, in: view)
        delegate?.strokeInputDidBegin(self)
        addSamples(for: touch, event: event, in: view, layout: layout, predict: true)
        if let first = samples.first {
            print("Stroke began: \(touch.type == .pencil ? "pencil" : "finger"), force \(first.force), "
                  + "altitude \(first.altitude), azimuth \(first.azimuth)")
        }
        publish()
    }

    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView, layout: CanvasLayout) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        addSamples(for: touch, event: event, in: view, layout: layout, predict: true)
        publish()
    }

    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView, layout: CanvasLayout) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // The lift-off event still carries the last positions; nothing left to predict.
        addSamples(for: touch, event: event, in: view, layout: layout, predict: false)
        activeTouch = nil
        isAwaitingEnd = true
        publish() // ends right away when nothing is pending

        if isStrokeOpen {
            let generation = strokeGeneration
            Task { [weak self] in
                try? await Task.sleep(for: Self.updateTimeout)
                guard let self, self.strokeGeneration == generation, self.isAwaitingEnd else { return }
                self.finishWithEstimates()
            }
        }
    }

    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelStroke()
    }

    /// A multi-finger gesture fired: drop the stroke its first finger started.
    /// The gesture's action runs before UIKit cancels those touches, so this has to happen here.
    /// Returns false while the Pencil is drawing: the gesture should then do nothing.
    func yieldToFingerGesture() -> Bool {
        guard let touch = activeTouch else { return true }
        guard touch.type != .pencil else { return false }
        cancelStroke()
        return true
    }

    private func cancelStroke() {
        print("Stroke cancelled after \(samples.count) samples")
        resetStroke()
        delegate?.strokeInputDidCancel(self)
    }

    /// Final (or better) values for samples reported earlier as estimates.
    func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>, in view: UIView, layout: CanvasLayout) {
        for touch in touches {
            guard let updateIndex = touch.estimationUpdateIndex?.intValue else { continue }
            applyUpdate(updateIndex: updateIndex, isFinal: touch.estimatedPropertiesExpectingUpdates.isEmpty) { sample in
                if touch.type == .pencil, touch.maximumPossibleForce > 0 {
                    sample.force = min(1, Float(touch.force / touch.maximumPossibleForce))
                }
                sample.altitude = Float(touch.altitudeAngle)
                sample.azimuth = Float(touch.azimuthAngle(in: view))
                sample.position = layout.canvasPoint(fromViewPoint: touch.preciseLocation(in: view))
            }
        }
        publish()
    }

    // MARK: - Stroke state

    private func startStroke(_ touch: UITouch, in view: UIView) {
        resetStroke()
        activeTouch = touch
        isStrokeOpen = true
        strokeGeneration += 1
        strokeStartTime = touch.timestamp
        lastTimestamp = touch.timestamp
        lastViewPosition = SIMD2(touch.preciseLocation(in: view))
    }

    private func resetStroke() {
        activeTouch = nil
        isStrokeOpen = false
        isAwaitingEnd = false
        hasPreviousSample = false
        emulatedPressure = 1
        samples.removeAll()
        isFinal.removeAll()
        committedCount = 0
        pendingUpdates.removeAll()
        predicted.removeAll()
        eventCount = 0
        predictedSampleCount = 0
        estimates.removeAll()
        updatedCount = 0
        updateDelaySum = 0
        forceChangeSum = 0
        forceChangeMax = 0
        timedOutCount = 0
    }

    /// Commits the final prefix, refreshes the tail, and ends the stroke once everything is final.
    private func publish() {
        guard isStrokeOpen else { return }
        var committed: [InputSample] = []
        while committedCount < samples.count, isFinal[committedCount] {
            committed.append(samples[committedCount])
            committedCount += 1
        }
        if !committed.isEmpty {
            delegate?.strokeInput(self, didCommit: committed)
        }
        delegate?.strokeInput(self, didUpdateTail: Array(samples[committedCount...]), predicted: predicted)

        if isAwaitingEnd, committedCount == samples.count {
            logStroke()
            resetStroke()
            delegate?.strokeInputDidEnd(self)
        }
    }

    /// Updates did not arrive in time: keep the estimates.
    private func finishWithEstimates() {
        timedOutCount += samples.count - committedCount
        for index in committedCount..<samples.count {
            isFinal[index] = true
        }
        pendingUpdates.removeAll()
        publish()
    }

    private func applyUpdate(updateIndex: Int, isFinal final: Bool, _ update: (inout InputSample) -> Void) {
        // Late updates for an ended stroke find nothing here and are ignored.
        guard let index = pendingUpdates[updateIndex] else { return }
        update(&samples[index])
        guard final else { return }
        isFinal[index] = true
        pendingUpdates[updateIndex] = nil
        if let estimate = estimates.removeValue(forKey: index) {
            let change = abs(samples[index].force - estimate.force)
            updatedCount += 1
            updateDelaySum += ProcessInfo.processInfo.systemUptime - estimate.time
            forceChangeSum += change
            forceChangeMax = max(forceChangeMax, change)
        }
    }

    // MARK: - Samples

    /// Converts all coalesced touches of this event (up to 240 Hz for Pencil) into samples,
    /// and keeps UIKit's predicted positions for the tail.
    private func addSamples(for touch: UITouch, event: UIEvent?, in view: UIView, layout: CanvasLayout,
                            predict: Bool) {
        let measured = event?.coalescedTouches(for: touch) ?? [touch]
        for measuredTouch in measured {
            guard let sample = makeSample(from: measuredTouch, in: view, layout: layout) else { continue }
            append(sample, updateIndex: updateIndex(for: measuredTouch))
        }
        eventCount += 1

        predicted = predict
            ? (event?.predictedTouches(for: touch) ?? []).map { makePredictedSample(from: $0, in: view, layout: layout) }
            : []
        predictedSampleCount += predicted.count
    }

    private func append(_ sample: InputSample, updateIndex: Int?) {
        let index = samples.count
        samples.append(sample)
        isFinal.append(updateIndex == nil)
        guard let updateIndex else { return }
        pendingUpdates[updateIndex] = index
        estimates[index] = (sample.force, ProcessInfo.processInfo.systemUptime)
        if updateIndex < 0 {
            scheduleSimulatedUpdate(updateIndex)
        }
    }

    /// Index to match a later update, or nil when the sample is already final.
    private func updateIndex(for touch: UITouch) -> Int? {
        if !touch.estimatedPropertiesExpectingUpdates.isEmpty, let index = touch.estimationUpdateIndex {
            return index.intValue
        }
        if Self.simulateEstimatedUpdates, touch.type != .pencil {
            nextSimulatedIndex += 1
            return -nextSimulatedIndex // negative: never collides with UIKit's indices
        }
        return nil
    }

    private func scheduleSimulatedUpdate(_ updateIndex: Int) {
        let generation = strokeGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Self.simulatedUpdateDelay)
            guard let self, self.strokeGeneration == generation else { return }
            self.applyUpdate(updateIndex: updateIndex, isFinal: true) { sample in
                sample.force *= 0.6 // visibly different from the estimate
            }
            self.publish()
        }
    }

    /// Returns nil for a touch that did not move since the previous sample
    /// (e.g. lift-off repeats the last position): it would stamp the same spot twice.
    private func makeSample(from touch: UITouch, in view: UIView, layout: CanvasLayout) -> InputSample? {
        // preciseLocation keeps the sub-point precision the Pencil provides.
        let viewPoint = touch.preciseLocation(in: view)
        let viewPosition = SIMD2<Float>(viewPoint)
        if hasPreviousSample, viewPosition == lastViewPosition {
            return nil
        }
        hasPreviousSample = true

        let force: Float
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            force = min(1, Float(touch.force / touch.maximumPossibleForce))
        } else {
            force = emulatePressure(viewPosition: viewPosition, timestamp: touch.timestamp)
        }
        lastViewPosition = viewPosition
        lastTimestamp = touch.timestamp

        return InputSample(position: layout.canvasPoint(fromViewPoint: viewPoint),
                           force: force,
                           altitude: Float(touch.altitudeAngle),
                           azimuth: Float(touch.azimuthAngle(in: view)),
                           timestamp: touch.timestamp - strokeStartTime)
    }

    /// Like makeSample, but changes no state: a prediction is thrown away on the next event.
    private func makePredictedSample(from touch: UITouch, in view: UIView, layout: CanvasLayout) -> InputSample {
        let force: Float
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            force = min(1, Float(touch.force / touch.maximumPossibleForce))
        } else {
            force = emulatedPressure // keep the current pseudo-pressure, do not update it
        }
        return InputSample(position: layout.canvasPoint(fromViewPoint: touch.preciseLocation(in: view)),
                           force: force,
                           altitude: Float(touch.altitudeAngle),
                           azimuth: Float(touch.azimuthAngle(in: view)),
                           timestamp: touch.timestamp - strokeStartTime)
    }

    /// Speed in view points per second -> smoothed pseudo-pressure.
    private func emulatePressure(viewPosition: SIMD2<Float>, timestamp: TimeInterval) -> Float {
        let dt = Float(timestamp - lastTimestamp)
        guard dt > 0 else { return emulatedPressure }
        let speed = simd_distance(viewPosition, lastViewPosition) / dt
        let t = simd_clamp((speed - fullPressureSpeed) / (minPressureSpeed - fullPressureSpeed), 0, 1)
        let target = 1 - t * (1 - minEmulatedPressure)
        emulatedPressure = pressureSmoothing * emulatedPressure + (1 - pressureSmoothing) * target
        return emulatedPressure
    }

    private func logStroke() {
        let duration = samples.last?.timestamp ?? 0
        print("Stroke ended: \(eventCount) events, \(samples.count) samples, "
              + "\(predictedSampleCount) predicted, " + String(format: "%.2f s", duration))
        guard updatedCount + timedOutCount > 0 else { return }
        let average = updatedCount > 0 ? Double(updatedCount) : 1
        print(String(format: "  estimated: %d updated (delay avg %.1f ms), |Δforce| avg %.3f max %.3f, %d kept after timeout",
                     updatedCount, updateDelaySum / average * 1000, Double(forceChangeSum) / average,
                     Double(forceChangeMax), timedOutCount))
    }
}
