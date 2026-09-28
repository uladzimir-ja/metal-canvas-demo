import Foundation

/// One measured point of a stroke, independent of the input device.
struct InputSample: Codable {
    var position: SIMD2<Float>   // canvas pixels, origin top-left
    var force: Float             // 0...1, normalized (Pencil) or emulated from speed
    var altitude: Float          // radians, π/2 = perpendicular to the screen
    var azimuth: Float           // radians, direction the Pencil points to
    var timestamp: TimeInterval  // seconds since stroke start
}
