import Foundation
import simd

/// Point on the smoothed stroke where a stamp is placed.
struct StampPoint {
    var position: SIMD2<Float> // canvas pixels
    var force: Float
    var altitude: Float
    var azimuth: Float
}

/// Smooths input samples with a centripetal Catmull-Rom spline
/// and places stamps along it at even spacing (a fraction of the brush diameter).
struct StrokeProcessor {
    /// Distance between stamps as a fraction of the diameter at that point.
    let spacing: Float
    /// Brush diameter in canvas pixels for a stamp (depends on force, later on tilt).
    let diameter: (StampPoint) -> Float

    // Sliding window of control points; a segment P1 -> P2 needs neighbours P0 and P3.
    private var window: [InputSample] = []
    private var distanceToNextStamp: Float = 0

    init(spacing: Float, diameter: @escaping (StampPoint) -> Float) {
        self.spacing = spacing
        self.diameter = diameter
    }

    /// Adds a sample and returns stamps for every segment that became complete.
    mutating func add(_ sample: InputSample) -> [StampPoint] {
        if window.isEmpty {
            // Start point doubles as its own left neighbour; a tap still leaves a dot.
            window = [sample, sample]
            let first = StampPoint(sample)
            distanceToNextStamp = stepLength(at: first)
            return [first]
        }
        window.append(sample)
        return drainCompleteSegment()
    }

    /// Ends the stroke: the last point doubles as its own right neighbour.
    mutating func finish() -> [StampPoint] {
        guard let last = window.last else { return [] }
        window.append(last)
        let stamps = drainCompleteSegment()
        window.removeAll()
        return stamps
    }

    private mutating func drainCompleteSegment() -> [StampPoint] {
        guard window.count == 4 else { return [] }
        let stamps = stampSegment(window[0].position, window[1], window[2], window[3].position)
        window.removeFirst()
        return stamps
    }

    // MARK: - Segment

    /// Walks the curve from s1 to s2 and emits a stamp every `stepLength`.
    private mutating func stampSegment(_ p0: SIMD2<Float>, _ s1: InputSample, _ s2: InputSample,
                                       _ p3: SIMD2<Float>) -> [StampPoint] {
        let p1 = s1.position
        let p2 = s2.position
        let chord = simd_distance(p1, p2)
        guard chord > 0 else { return [] }
        // Duplicated end points have no direction: mirror the neighbour instead.
        let q0 = simd_distance(p0, p1) > 0 ? p0 : 2 * p1 - p2
        let q3 = simd_distance(p2, p3) > 0 ? p3 : 2 * p2 - p1
        let curve = CentripetalCatmullRom(q0, p1, p2, q3)

        // No closed form for the arc length: approximate with short straight pieces (~2 px).
        let pieces = max(1, Int((chord / 2).rounded(.up)))
        var stamps: [StampPoint] = []
        var start = p1
        var startU: Float = 0
        for i in 1...pieces {
            let u = Float(i) / Float(pieces)
            let end = i == pieces ? p2 : curve.point(at: u)
            var remaining = simd_distance(start, end)
            // Place as many stamps on this piece as fit; the leftover carries over.
            while remaining >= distanceToNextStamp {
                let f = distanceToNextStamp / remaining
                let position = simd_mix(start, end, SIMD2(repeating: f))
                let stampU = startU + (u - startU) * f
                let stamp = StampPoint(interpolating: s1, s2, at: stampU, position: position)
                stamps.append(stamp)
                remaining -= distanceToNextStamp
                start = position
                startU = stampU
                distanceToNextStamp = stepLength(at: stamp)
            }
            distanceToNextStamp -= remaining
            start = end
            startU = u
        }
        return stamps
    }

    private func stepLength(at stamp: StampPoint) -> Float {
        // Lower bound keeps the loop finite for a zero-size brush.
        max(0.5, spacing * diameter(stamp))
    }
}

// MARK: - Helpers

/// Centripetal Catmull-Rom (alpha = 0.5) between p1 and p2, Barry–Goldman form.
/// Knot spacing grows with the square root of the distance, which prevents loops and overshoot.
private struct CentripetalCatmullRom {
    let p0, p1, p2, p3: SIMD2<Float>
    let t0: Float = 0
    let t1, t2, t3: Float

    init(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        t1 = sqrt(simd_distance(p0, p1))
        t2 = t1 + sqrt(simd_distance(p1, p2))
        t3 = t2 + sqrt(simd_distance(p2, p3))
    }

    /// u = 0 at p1, u = 1 at p2.
    func point(at u: Float) -> SIMD2<Float> {
        let t = t1 + (t2 - t1) * u
        let a1 = lerp(p0, p1, t0, t1, t)
        let a2 = lerp(p1, p2, t1, t2, t)
        let a3 = lerp(p2, p3, t2, t3, t)
        let b1 = lerp(a1, a2, t0, t2, t)
        let b2 = lerp(a2, a3, t1, t3, t)
        return lerp(b1, b2, t1, t2, t)
    }

    /// Value at t on the line through (ta, a) and (tb, b).
    private func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ ta: Float, _ tb: Float, _ t: Float) -> SIMD2<Float> {
        simd_mix(a, b, SIMD2(repeating: (t - ta) / (tb - ta)))
    }
}

private extension StampPoint {
    init(_ sample: InputSample) {
        self.init(position: sample.position, force: sample.force,
                  altitude: sample.altitude, azimuth: sample.azimuth)
    }

    /// Position from the curve, other attributes linearly between the two samples.
    init(interpolating a: InputSample, _ b: InputSample, at u: Float, position: SIMD2<Float>) {
        // Azimuth wraps around: go the short way (e.g. 350° -> 10° through 0°).
        let azimuthDelta = remainder(b.azimuth - a.azimuth, 2 * Float.pi)
        self.init(position: position,
                  force: a.force + (b.force - a.force) * u,
                  altitude: a.altitude + (b.altitude - a.altitude) * u,
                  azimuth: a.azimuth + azimuthDelta * u)
    }
}
