import Metal
import simd

/// Brush shape and grain textures generated in code (no image assets), cached by name.
final class BrushTextures {
    enum TextureError: Error {
        case unknownName(String)
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var cache: [String: MTLTexture] = [:]

    /// 1×1 white: "no grain" without a branch in the shader.
    private(set) lazy var white: MTLTexture = makeTexture(size: 1, pixels: [255], mipmapped: false, label: "White")

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
    }

    /// Accepts names with or without extension ("paper" or "paper.png").
    func texture(named fileName: String) throws -> MTLTexture {
        let name = (fileName as NSString).deletingPathExtension
        if let cached = cache[name] {
            return cached
        }
        let texture: MTLTexture
        switch name {
        case "round_soft":
            texture = makeTexture(size: 128, pixels: Self.roundSoft(size: 128), mipmapped: true, label: name)
        case "pencil_tip":
            texture = makeTexture(size: 128, pixels: Self.pencilTip(size: 128), mipmapped: true, label: name)
        case "paper":
            // Tiled, sampled roughly 1:1 in canvas pixels: no mipmaps needed.
            texture = makeTexture(size: 256, pixels: Self.paper(size: 256), mipmapped: false, label: name)
        default:
            throw TextureError.unknownName(fileName)
        }
        cache[name] = texture
        return texture
    }

    // MARK: - Upload

    /// CPU pixels -> staging buffer -> private texture via a blit pass, plus mipmaps.
    private func makeTexture(size: Int, pixels: [UInt8], mipmapped: Bool, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size,
                                                                  mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: pixels, length: pixels.count),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            fatalError("Cannot create brush texture \(label)")
        }
        texture.label = label
        blit.label = "Upload \(label)"
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: size, sourceBytesPerImage: pixels.count,
                  sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if mipmapped {
            // Each level is a filtered half-size copy of the previous one.
            blit.generateMipmaps(for: texture)
        }
        blit.endEncoding()
        commandBuffer.commit()
        // One-time setup: waiting is fine here, never do this per frame.
        commandBuffer.waitUntilCompleted()
        return texture
    }

    // MARK: - Generators

    /// Same profile as the old procedural stamp: solid core, smooth falloff.
    private static func roundSoft(size: Int) -> [UInt8] {
        pixels(size: size) { p in
            1 - smoothstep(0.5, 1, simd_length(p))
        }
    }

    /// Graphite tip: disc with a ragged edge and uneven density.
    private static func pencilTip(size: Int) -> [UInt8] {
        let edgeNoise = PeriodicNoise(period: 8, maxOctaves: 2, seed: 11)
        let densityNoise = PeriodicNoise(period: 16, maxOctaves: 2, seed: 23)
        return pixels(size: size) { p in
            let distance = simd_length(p)
            // Sample noise along a circle: the edge wobble is continuous all the way round.
            let angle = atan2(p.y, p.x)
            let edgePoint = SIMD2(cos(angle), sin(angle)) * 1.5 + 4
            let edge = 0.8 + 0.2 * edgeNoise.fbm(edgePoint, octaves: 2)
            let disc = 1 - smoothstep(edge * 0.7, edge, distance)
            let density = 0.65 + 0.35 * densityNoise.fbm((p + 1) * 8, octaves: 2)
            return disc * density
        }
    }

    /// Paper height map: bumps of 1–2 px (paper tooth). Graphite sticks to bumps above a pressure-dependent level.
    /// Heights are histogram-equalized (uniform 0...1), so a threshold t covers exactly 1 - t of the area.
    private static func paper(size: Int) -> [UInt8] {
        let noise = PeriodicNoise(period: 128, maxOctaves: 2, seed: 7)
        let heights = (0..<size * size).map { index in
            // Noise coordinates span exactly one period over the texture: seamless tiling.
            let point = SIMD2(Float(index % size), Float(index / size)) / Float(size) * 128
            return noise.fbm(point, octaves: 2)
        }
        // Rank of each pixel -> its height: flat histogram, same bump shapes.
        var equalized = [UInt8](repeating: 0, count: heights.count)
        let order = heights.indices.sorted { heights[$0] < heights[$1] }
        for (rank, index) in order.enumerated() {
            equalized[index] = UInt8(rank * 255 / (order.count - 1))
        }
        return equalized
    }

    /// Evaluates `value` for every pixel; `p` is in -1...1 across the texture (pixel centers).
    private static func pixels(size: Int, value: (SIMD2<Float>) -> Float) -> [UInt8] {
        (0..<size * size).map { index in
            let pixel = SIMD2(Float(index % size), Float(index / size)) + 0.5
            let p = pixel / Float(size) * 2 - 1
            return UInt8(simd_clamp(value(p), 0, 1) * 255)
        }
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }
}

/// Value noise on a lattice that wraps around every `period` cells, so it tiles seamlessly.
private struct PeriodicNoise {
    let period: Int
    private let latticeSize: Int
    private let lattice: [Float]

    init(period: Int, maxOctaves: Int, seed: UInt64) {
        self.period = period
        var random = SplitMix64(seed: seed)
        // The finest octave has period * 2^(maxOctaves - 1) cells per side.
        latticeSize = period << (maxOctaves - 1)
        lattice = (0..<latticeSize * latticeSize).map { _ in random.nextUnitFloat() }
    }

    /// Sum of octaves (fractal Brownian motion), normalized to 0...1.
    func fbm(_ point: SIMD2<Float>, octaves: Int) -> Float {
        var sum: Float = 0
        var amplitude: Float = 1
        var total: Float = 0
        for octave in 0..<octaves {
            let frequency = 1 << octave
            sum += amplitude * value(point * Float(frequency), period: period * frequency)
            total += amplitude
            amplitude *= 0.5
        }
        return sum / total
    }

    /// Bilinear value noise with smooth interpolation; lattice indices wrap at `period`.
    private func value(_ point: SIMD2<Float>, period: Int) -> Float {
        let stride = latticeSize // lattice row length
        precondition(period <= stride, "More octaves than maxOctaves")
        let cell = SIMD2(floor(point.x), floor(point.y))
        let f = point - cell
        let t = f * f * (3 - 2 * f)
        let x0 = wrap(Int(cell.x), period), x1 = wrap(Int(cell.x) + 1, period)
        let y0 = wrap(Int(cell.y), period), y1 = wrap(Int(cell.y) + 1, period)
        func at(_ x: Int, _ y: Int) -> Float { lattice[y * stride + x] }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * t.x
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * t.x
        return top + (bottom - top) * t.y
    }

    private func wrap(_ value: Int, _ period: Int) -> Int {
        ((value % period) + period) % period
    }
}

/// Small deterministic RNG: same seed, same texture on every launch.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
