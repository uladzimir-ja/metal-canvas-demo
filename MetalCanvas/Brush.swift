import Foundation
import simd

/// Brush preset as data (loaded from JSON). All dynamics live here.
struct Brush: Codable {
    enum Mode: String, Codable {
        case paint // adds color to the canvas
        case erase // removes paint: canvas x (1 - coverage)
    }

    enum StampBlend: String, Codable {
        case max  // stroke coverage = strongest stamp: overlaps inside a stroke never darken
        case over // coverage builds up with flow, like paint
    }

    enum GrainSpace: String, Codable {
        case canvas // fixed paper texture: the same grain under every stamp
        case stamp  // grain moves and turns with each stamp
    }

    struct Pressure: Codable {
        var size: Float    // 0 = pressure ignored, 1 = full min...max size range
        var opacity: Float // 0 = pressure ignored, 1 = light touch is fully transparent
    }

    struct Tilt: Codable {
        var size: Float    // extra size when the Pencil lies flat: diameter x (1 + size)
    }

    struct Jitter: Codable {
        var rotation: Float // fraction of a half turn: 1 = random angle in ±180°
    }

    var id: String
    var renderer: String
    var mode: Mode?        // paint when absent (older presets and recordings)
    var stampBlend: StampBlend
    var spacing: Float     // stamp step as a fraction of the diameter
    var size: [Float]      // [min, max] diameter in view points
    var flow: Float        // alpha of one stamp
    var opacity: Float     // cap for the whole stroke, applied when it is composited
    var pressure: Pressure
    var tilt: Tilt?
    var shape: String?         // generated texture name; round_soft when absent
    var grain: String?         // generated texture name; no grain when absent
    var grainSpace: GrainSpace?
    var grainScale: Float?     // canvas pixels per grain texel
    var grainStrength: Float?  // 0...1
    var jitter: Jitter?

    var effectiveMode: Mode { mode ?? .paint }
    var minSize: Float { size[0] }
    var maxSize: Float { size[1] }

    /// Pencil tilt starts to widen the stamp below this altitude; normal writing angles are unaffected.
    private static let tiltStartAltitude = Float.pi / 4

    static func load(named name: String) throws -> Brush {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        let brush = try JSONDecoder().decode(Brush.self, from: Data(contentsOf: url))
        guard brush.size.count == 2, brush.minSize <= brush.maxSize, brush.spacing > 0 else {
            throw CocoaError(.coderInvalidValue)
        }
        return brush
    }

    /// Stamp diameter in view points.
    func diameter(for point: StampPoint) -> Float {
        let pressured = minSize + (maxSize - minSize) * point.force
        var diameter = maxSize + (pressured - maxSize) * pressure.size
        if let tilt {
            // 0 when the Pencil is at 45° or steeper, 1 when it lies flat.
            let tiltAmount = simd_clamp(1 - point.altitude / Self.tiltStartAltitude, 0, 1)
            diameter *= 1 + tilt.size * tiltAmount
        }
        return diameter
    }

    /// Coverage of one stamp.
    func stampAlpha(for point: StampPoint) -> Float {
        flow * (1 - pressure.opacity * (1 - point.force))
    }

    /// Stamp rotation in radians. Pseudo-random but deterministic per stamp index,
    /// so replaying a recorded stroke gives exactly the same pixels.
    func rotation(forStampIndex index: Int) -> Float {
        guard let jitter, jitter.rotation > 0 else { return 0 }
        return Self.hashToSignedUnit(UInt32(truncatingIfNeeded: index)) * jitter.rotation * .pi
    }

    /// Integer hash (Wang) -> -1...1.
    private static func hashToSignedUnit(_ value: UInt32) -> Float {
        var x = value
        x = (x ^ 61) ^ (x >> 16)
        x &*= 9
        x ^= x >> 4
        x &*= 0x27d4_eb2d
        x ^= x >> 15
        return Float(x) / Float(UInt32.max) * 2 - 1
    }
}
