import Foundation
import simd

/// Outline to trace: a closed polyline in canvas pixels.
struct TraceTarget {
    enum Shape: String, CaseIterable {
        case circle
        case star
    }

    let shape: Shape
    let points: [SIMD2<Float>] // closed: the last point connects back to the first

    init(_ shape: Shape, canvasSize: Float) {
        self.shape = shape
        let center = SIMD2(repeating: canvasSize / 2)
        switch shape {
        case .circle:
            // 128 segments: the chord error at radius 700 px is below 0.3 px.
            points = Self.polygon(center: center, count: 128, radius: { _ in canvasSize * 0.34 })
        case .star:
            // Five points, alternating outer and inner vertices, first point straight up.
            points = Self.polygon(center: center, count: 10, radius: { $0.isMultiple(of: 2) ? canvasSize * 0.36 : canvasSize * 0.15 })
        }
    }

    /// Points along the outline every `spacing` pixels (for the coverage check).
    func samples(spacing: Float) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let steps = max(1, Int((simd_distance(a, b) / spacing).rounded(.up)))
            for step in 0..<steps {
                result.append(simd_mix(a, b, SIMD2(repeating: Float(step) / Float(steps))))
            }
        }
        return result
    }

    private static func polygon(center: SIMD2<Float>, count: Int, radius: (Int) -> Float) -> [SIMD2<Float>] {
        (0..<count).map { index in
            let angle = Float(index) / Float(count) * 2 * .pi - .pi / 2 // canvas y points down: -π/2 is up
            return center + SIMD2(cos(angle), sin(angle)) * radius(index)
        }
    }
}
