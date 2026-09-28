import Metal

/// Checks how well the canvas traces a target outline, on the GPU.
///
/// A distance field (distance to the outline per texel) is built once per target by a compute kernel.
/// It drives the on-screen guide and the live highlight, and the metrics:
/// accuracy = drawn pixels within tolerance / drawn pixels,
/// coverage = outline samples with paint nearby / outline samples.
/// Metrics read the canvas itself, so erasing and undo are taken into account automatically.
final class TraceEvaluator {
    struct Result: Equatable {
        var accuracy: Float? // nil while nothing is drawn
        var coverage: Float
    }

    static let tolerance: Float = 24        // canvas pixels (~10 pt at the fitted scale)
    private static let fieldScale = 2       // canvas pixels per field texel: 1024² field, 2 MB
    private static let sampleSpacing: Float = 4
    private static let drawnAlpha: Float = 0.2

    private(set) var target: TraceTarget?
    private(set) var field: MTLTexture?
    private var sampleCount = 0
    private var outlinePoints: MTLBuffer?
    private var outlineSamples: MTLBuffer?

    private let device: MTLDevice
    private let fieldPipeline: MTLComputePipelineState
    private let accuracyPipeline: MTLComputePipelineState
    private let coveragePipeline: MTLComputePipelineState
    /// dispatchThreads needs non-uniform threadgroups: Apple4 and newer (A12X is Apple5).
    private let supportsNonUniformThreadgroups: Bool

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        fieldPipeline = Self.makePipeline(device: device, library: library, function: "distanceFieldKernel")
        accuracyPipeline = Self.makePipeline(device: device, library: library, function: "traceAccuracyKernel")
        coveragePipeline = Self.makePipeline(device: device, library: library, function: "traceCoverageKernel")
        supportsNonUniformThreadgroups = device.supportsFamily(.apple4)
        print("Compute dispatch: \(supportsNonUniformThreadgroups ? "dispatchThreads" : "dispatchThreadgroups + bounds check")")
    }

    var uniforms: TraceUniforms {
        TraceUniforms(tolerance: Self.tolerance, canvasPerField: Float(Self.fieldScale), drawnAlpha: Self.drawnAlpha,
                      searchRadius: Self.tolerance / 2, pointCount: 0, guideWidth: 1.5)
    }

    /// Sets the outline and encodes the distance field build; nil removes the target.
    func setTarget(_ target: TraceTarget?, canvasSize: Int, commandBuffer: MTLCommandBuffer) {
        self.target = target
        guard let target else {
            field = nil
            return
        }
        let samples = target.samples(spacing: Self.sampleSpacing)
        sampleCount = samples.count
        outlinePoints = makeBuffer(target.points, label: "Outline points")
        outlineSamples = makeBuffer(samples, label: "Outline samples")

        let fieldSize = canvasSize / Self.fieldScale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: fieldSize,
                                                                  height: fieldSize, mipmapped: false)
        // Written by the kernel, then sampled by the guide, the highlight and the accuracy kernel.
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let field = device.makeTexture(descriptor: descriptor),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            fatalError("Cannot create distance field")
        }
        field.label = "Distance field"
        self.field = field

        var params = uniforms
        params.pointCount = Int32(target.points.count)
        encoder.label = "Distance field"
        encoder.setComputePipelineState(fieldPipeline)
        encoder.setTexture(field, index: TextureIndex.distance.rawValue)
        encoder.setBuffer(outlinePoints, offset: 0, index: ComputeIndex.points.rawValue)
        encoder.setBytes(&params, length: MemoryLayout<TraceUniforms>.stride, index: ComputeIndex.uniforms.rawValue)
        dispatch(encoder, pipeline: fieldPipeline, width: fieldSize, height: fieldSize)
        encoder.endEncoding()
    }

    /// Encodes both metric kernels over the current canvas; `completion` gets the result on the main actor.
    /// Call after the passes that change the canvas in the same command buffer: GPU order follows encode order.
    func encodeEvaluation(canvas: MTLTexture, into commandBuffer: MTLCommandBuffer,
                          completion: @escaping @MainActor (Result) -> Void) {
        guard let field, let outlineSamples,
              let counters = device.makeBuffer(length: Int(TRACE_COUNTER_COUNT) * MemoryLayout<UInt32>.stride,
                                               options: .storageModeShared),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        // A fresh 12-byte buffer per evaluation: no reuse while a previous one may still be in flight.
        counters.label = "Trace counters"
        counters.contents().initializeMemory(as: UInt32.self, repeating: 0, count: Int(TRACE_COUNTER_COUNT))

        encoder.label = "Trace evaluation"
        var params = uniforms
        encoder.setTexture(canvas, index: TextureIndex.image.rawValue)
        encoder.setBuffer(counters, offset: 0, index: ComputeIndex.counters.rawValue)

        encoder.setComputePipelineState(accuracyPipeline)
        encoder.setTexture(field, index: TextureIndex.distance.rawValue)
        encoder.setBytes(&params, length: MemoryLayout<TraceUniforms>.stride, index: ComputeIndex.uniforms.rawValue)
        dispatch(encoder, pipeline: accuracyPipeline, width: canvas.width, height: canvas.height)

        params.pointCount = Int32(sampleCount)
        encoder.setComputePipelineState(coveragePipeline)
        encoder.setBuffer(outlineSamples, offset: 0, index: ComputeIndex.points.rawValue)
        encoder.setBytes(&params, length: MemoryLayout<TraceUniforms>.stride, index: ComputeIndex.uniforms.rawValue)
        dispatch(encoder, pipeline: coveragePipeline, width: sampleCount, height: 1)
        encoder.endEncoding()

        // Read back on Metal's completion thread: copy the numbers out, hand plain values to the main actor.
        let sampleCount = sampleCount
        nonisolated(unsafe) let buffer = counters // not touched by anyone else once the GPU is done
        commandBuffer.addCompletedHandler { @Sendable _ in
            let values = buffer.contents().bindMemory(to: UInt32.self, capacity: Int(TRACE_COUNTER_COUNT))
            let drawn = values[Int(TRACE_COUNTER_DRAWN)]
            let accurate = values[Int(TRACE_COUNTER_ACCURATE)]
            let covered = values[Int(TRACE_COUNTER_COVERED)]
            let result = Result(accuracy: drawn > 0 ? Float(accurate) / Float(drawn) : nil,
                                coverage: sampleCount > 0 ? Float(covered) / Float(sampleCount) : 0)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    // MARK: - Helpers

    /// Grid of `width` x `height` threads; threadgroup shape from the pipeline's SIMD width.
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let simdWidth = pipeline.threadExecutionWidth // 32 on Apple GPUs
        let group = height > 1
            ? MTLSize(width: simdWidth, height: pipeline.maxTotalThreadsPerThreadgroup / simdWidth, depth: 1)
            : MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        if supportsNonUniformThreadgroups {
            // Exactly width x height threads; the edge groups are just smaller.
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
        } else {
            // Whole groups, rounded up; the kernels skip threads outside the grid.
            let groups = MTLSize(width: (width + group.width - 1) / group.width,
                                 height: (height + group.height - 1) / group.height, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        }
    }

    private func makeBuffer(_ points: [SIMD2<Float>], label: String) -> MTLBuffer {
        guard let buffer = device.makeBuffer(bytes: points, length: MemoryLayout<SIMD2<Float>>.stride * points.count) else {
            fatalError("Cannot allocate \(label)")
        }
        buffer.label = label
        return buffer
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, function: String) -> MTLComputePipelineState {
        guard let kernel = library.makeFunction(name: function) else {
            fatalError("Missing kernel \(function)")
        }
        do {
            return try device.makeComputePipelineState(function: kernel)
        } catch {
            fatalError("Compute pipeline \(function): \(error)")
        }
    }
}
