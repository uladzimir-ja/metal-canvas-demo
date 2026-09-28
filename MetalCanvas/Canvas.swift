import Metal

/// Persistent drawing surface plus the stroke in progress.
///
/// The current stroke accumulates coverage in its own single-channel texture.
/// It is shown over the canvas as a preview and merged into the canvas once,
/// with the stroke color and opacity (or as an eraser), when the stroke ends.
/// A predicted tail is redrawn from scratch every frame in a separate texture and only previewed.
final class Canvas {
    static let pixelSize = 2048

    /// Everything the GPU needs to know about the brush for one stroke.
    struct StrokeStyle {
        var mode: Brush.Mode
        var color: SIMD3<Float>
        var opacity: Float
        var blend: Brush.StampBlend
        var shape: MTLTexture
        var grain: MTLTexture
        var grainScale: Float
        var grainStrength: Float
        var grainSpace: Brush.GrainSpace
    }

    /// Target outline shown under the canvas; also colors the live stroke by distance.
    struct TraceOverlay {
        var field: MTLTexture
        var uniforms: TraceUniforms
    }

    let texture: MTLTexture                  // finished strokes, premultiplied BGRA
    private let strokeTexture: MTLTexture     // coverage of the current stroke, R8
    private let predictionTexture: MTLTexture // coverage of the predicted tail, R8, rebuilt every frame
    private var checkpointTexture: MTLTexture? // copy of the canvas for undo, created on first use
    private let device: MTLDevice
    private let quadVertices: MTLBuffer
    private let instanceBuffers: StampBufferRing

    private let displayPipeline: MTLRenderPipelineState      // canvas texture -> screen
    private let erasePreviewPipeline: MTLRenderPipelineState // canvas minus eraser coverage -> screen
    private let compositePipeline: MTLRenderPipelineState    // stroke coverage -> canvas or screen
    private let previewPipeline: MTLRenderPipelineState      // max(stroke, prediction) -> screen
    private let eraseMergePipeline: MTLRenderPipelineState   // eraser coverage takes paint out of the canvas
    private let traceGuidePipeline: MTLRenderPipelineState   // target outline -> screen
    private let tracePreviewPipeline: MTLRenderPipelineState // live stroke colored by distance -> screen
    private let stampOverPipeline: MTLRenderPipelineState    // stamps -> stroke, build-up
    private let stampMaxPipeline: MTLRenderPipelineState     // stamps -> stroke, strongest wins

    // C struct from ShaderTypes.h: same memory layout as the shader reads, copied as is.
    private var pendingStamps: [StampInstance] = []
    // Texture memory is undefined after creation, first pass clears it.
    private var canvasNeedsClear = true
    private var needsCheckpointSave = false
    private var needsCheckpointRestore = false

    // Current stroke state.
    private var strokeStyle: StrokeStyle?
    private var strokeComposite = StrokeCompositeUniforms(color: .zero)
    private var isStrokeVisible = false
    private var strokeNeedsClear = false
    private(set) var strokeNeedsMerge = false

    // Predicted tail: replaced on every input event.
    private var pendingPrediction: [StampInstance] = []
    private var predictionNeedsEncode = false
    private var isPredictionVisible = false

    init(device: MTLDevice, library: MTLLibrary, screenPixelFormat: MTLPixelFormat) {
        self.device = device
        texture = Self.makeTexture(device: device, pixelFormat: .bgra8Unorm, label: "Canvas")
        // One byte per pixel: 4 MB instead of 16 MB, color is applied at composite time.
        strokeTexture = Self.makeTexture(device: device, pixelFormat: .r8Unorm, label: "Stroke coverage")
        predictionTexture = Self.makeTexture(device: device, pixelFormat: .r8Unorm, label: "Prediction coverage")
        // The composite pipeline draws both into the canvas and onto the screen.
        precondition(screenPixelFormat == texture.pixelFormat, "Canvas and screen formats must match")

        quadVertices = Self.makeQuadVertices(device: device)
        instanceBuffers = StampBufferRing(device: device)

        let format = texture.pixelFormat
        displayPipeline = Self.makePipeline(device: device, library: library, label: "Canvas display",
                                            vertex: "quadVertex", fragment: "quadFragment",
                                            pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        erasePreviewPipeline = Self.makePipeline(device: device, library: library, label: "Canvas erase preview",
                                                 vertex: "quadVertex", fragment: "canvasErasePreviewFragment",
                                                 pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        compositePipeline = Self.makePipeline(device: device, library: library, label: "Stroke composite",
                                              vertex: "quadVertex", fragment: "strokeCompositeFragment",
                                              pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        previewPipeline = Self.makePipeline(device: device, library: library, label: "Stroke preview",
                                            vertex: "quadVertex", fragment: "strokePreviewFragment",
                                            pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        // Same fragment as the paint merge: only its alpha matters with erase blending.
        eraseMergePipeline = Self.makePipeline(device: device, library: library, label: "Erase merge",
                                               vertex: "quadVertex", fragment: "strokeCompositeFragment",
                                               pixelFormat: format) { $0.enableEraseBlending() }
        traceGuidePipeline = Self.makePipeline(device: device, library: library, label: "Trace guide",
                                               vertex: "quadVertex", fragment: "traceGuideFragment",
                                               pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        tracePreviewPipeline = Self.makePipeline(device: device, library: library, label: "Trace stroke preview",
                                                 vertex: "quadVertex", fragment: "strokeTracePreviewFragment",
                                                 pixelFormat: format) { $0.enablePremultipliedAlphaBlending() }
        stampOverPipeline = Self.makePipeline(device: device, library: library, label: "Stamp over",
                                              vertex: "stampVertex", fragment: "stampFragment",
                                              pixelFormat: strokeTexture.pixelFormat) { $0.enablePremultipliedAlphaBlending() }
        stampMaxPipeline = Self.makePipeline(device: device, library: library, label: "Stamp max",
                                             vertex: "stampVertex", fragment: "stampFragment",
                                             pixelFormat: strokeTexture.pixelFormat) { $0.enableMaxBlending() }
    }

    // MARK: - Stroke

    func beginStroke(style: StrokeStyle) {
        precondition(!strokeNeedsMerge, "Encode the previous stroke's merge before starting a new one")
        strokeStyle = style
        strokeComposite = StrokeCompositeUniforms(color: SIMD4(style.color, style.opacity))
        isStrokeVisible = true
        strokeNeedsClear = true
        pendingStamps.removeAll(keepingCapacity: true)
    }

    func add(_ stamp: StampInstance) {
        pendingStamps.append(stamp)
    }

    /// Replaces the predicted tail; an empty array hides it.
    func setPrediction(_ stamps: [StampInstance]) {
        pendingPrediction = stamps
        predictionNeedsEncode = true
    }

    /// The stroke is merged into the canvas in the next encoded frame.
    func endStroke() {
        strokeNeedsMerge = true
    }

    /// Drops the stroke without touching the canvas.
    func cancelStroke() {
        isStrokeVisible = false
        isPredictionVisible = false
        strokeStyle = nil
        pendingStamps.removeAll(keepingCapacity: true)
        pendingPrediction.removeAll(keepingCapacity: true)
    }

    // MARK: - Whole canvas

    /// Erases the whole canvas in the next encoded frame.
    func clear() {
        canvasNeedsClear = true
        needsCheckpointRestore = false
    }

    /// Copies the canvas into the checkpoint after the next merge (a 16 MB blit, created on first use).
    func saveCheckpoint() {
        needsCheckpointSave = true
    }

    /// Replaces the canvas with the checkpoint copy in the next encoded frame.
    func restoreCheckpoint() {
        precondition(checkpointTexture != nil, "No checkpoint to restore")
        needsCheckpointRestore = true
        canvasNeedsClear = false
    }

    // MARK: - Encoding

    /// Offscreen work of a frame, in order: canvas clear or checkpoint restore, new stamps into the
    /// stroke and prediction textures, stroke merge, checkpoint save.
    /// Returns the number of stamp draw calls.
    @discardableResult
    func encodeOffscreenPasses(into commandBuffer: MTLCommandBuffer) -> Int {
        if needsCheckpointRestore, let checkpointTexture {
            encodeCopy(from: checkpointTexture, to: texture, into: commandBuffer, label: "Checkpoint restore")
            needsCheckpointRestore = false
        } else if canvasNeedsClear, !strokeNeedsMerge {
            encodeCanvasPass(into: commandBuffer, loadAction: .clear, label: "Canvas clear") { _ in }
        }

        let style = strokeStyle
        let stampCount = style == nil ? 0 : pendingStamps.count
        let predictionCount = style != nil && predictionNeedsEncode ? pendingPrediction.count : 0
        // Stroke stamps and the predicted tail share one ring buffer: one semaphore wait per frame.
        var instances: MTLBuffer?
        if stampCount + predictionCount > 0 {
            let buffer = instanceBuffers.acquire(count: stampCount + predictionCount, for: commandBuffer)
            let stride = MemoryLayout<StampInstance>.stride
            // An empty array may have no base address: copy only non-empty parts.
            if stampCount > 0 {
                pendingStamps.withUnsafeBytes { bytes in
                    buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: stampCount * stride)
                }
            }
            if predictionCount > 0 {
                pendingPrediction.withUnsafeBytes { bytes in
                    buffer.contents().advanced(by: stampCount * stride)
                        .copyMemory(from: bytes.baseAddress!, byteCount: predictionCount * stride)
                }
            }
            instances = buffer
        }

        var drawCalls = 0
        // Stroke: .clear at stroke start, then .load so it keeps growing.
        if strokeNeedsClear || stampCount > 0 {
            drawCalls += encodeStampPass(into: commandBuffer, target: strokeTexture,
                                         loadAction: strokeNeedsClear ? .clear : .load, label: "Stroke stamps",
                                         style: style, instances: instances, first: 0, count: stampCount)
            strokeNeedsClear = false
            pendingStamps.removeAll(keepingCapacity: true)
        }
        // Prediction: always rebuilt from scratch, never accumulated.
        if predictionNeedsEncode {
            if predictionCount > 0 {
                drawCalls += encodeStampPass(into: commandBuffer, target: predictionTexture,
                                             loadAction: .clear, label: "Prediction stamps",
                                             style: style, instances: instances, first: stampCount,
                                             count: predictionCount)
            }
            isPredictionVisible = predictionCount > 0
            predictionNeedsEncode = false
        }

        if strokeNeedsMerge {
            encodeMerge(into: commandBuffer)
        }
        if needsCheckpointSave {
            encodeCopy(from: texture, to: checkpoint(), into: commandBuffer, label: "Checkpoint save")
            needsCheckpointSave = false
        }
        return drawCalls
    }

    /// Guide (if tracing), canvas and, while drawing, the stroke preview on top. `encoder` targets the screen.
    func encodeScreen(into encoder: MTLRenderCommandEncoder, transform: simd_float3x3, trace: TraceOverlay?) {
        bindQuad(encoder, transform: transform)
        // Without a visible tail the stroke texture stands in for it: max(stroke, stroke) = stroke.
        let prediction = isPredictionVisible ? predictionTexture : strokeTexture
        encoder.setFragmentTexture(prediction, index: TextureIndex.prediction.rawValue)

        if var trace {
            // Under the canvas, like a printed template: graphite covers it.
            encoder.setRenderPipelineState(traceGuidePipeline)
            encoder.setFragmentTexture(trace.field, index: TextureIndex.distance.rawValue)
            encoder.setFragmentBytes(&trace.uniforms, length: MemoryLayout<TraceUniforms>.stride,
                                     index: FragmentInputIndex.uniforms.rawValue)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if isStrokeVisible, strokeStyle?.mode == .erase {
            // Eraser: show the canvas already reduced; the paper under it stays.
            encoder.setRenderPipelineState(erasePreviewPipeline)
            encoder.setFragmentTexture(texture, index: TextureIndex.image.rawValue)
            encoder.setFragmentTexture(strokeTexture, index: TextureIndex.coverage.rawValue)
            encoder.setFragmentBytes(&strokeComposite, length: MemoryLayout<StrokeCompositeUniforms>.stride,
                                     index: FragmentInputIndex.uniforms.rawValue)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return
        }

        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(texture, index: TextureIndex.image.rawValue)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        guard isStrokeVisible else { return }
        if var trace {
            // Live highlight: green within the tolerance, red outside.
            encoder.setFragmentTexture(trace.field, index: TextureIndex.distance.rawValue)
            encoder.setFragmentBytes(&trace.uniforms, length: MemoryLayout<TraceUniforms>.stride,
                                     index: FragmentInputIndex.trace.rawValue)
            encodeStrokeComposite(into: encoder, pipeline: tracePreviewPipeline)
        } else {
            encodeStrokeComposite(into: encoder, pipeline: isPredictionVisible ? previewPipeline : compositePipeline)
        }
    }

    /// Draws `count` stamps starting at instance `first` of `instances` into `target`.
    private func encodeStampPass(into commandBuffer: MTLCommandBuffer, target: MTLTexture,
                                 loadAction: MTLLoadAction, label: String, style: StrokeStyle?,
                                 instances: MTLBuffer?, first: Int, count: Int) -> Int {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return 0 }
        encoder.label = label

        var drawCalls = 0
        if count > 0, let style, let instances {
            var uniforms = StampPassUniforms(
                canvasSize: SIMD2(Float(texture.width), Float(texture.height)),
                grainScale: style.grainScale,
                grainStrength: style.grainStrength,
                grainSpace: style.grainSpace == .canvas ? GRAIN_SPACE_CANVAS : GRAIN_SPACE_STAMP)

            encoder.setRenderPipelineState(style.blend == .max ? stampMaxPipeline : stampOverPipeline)
            encoder.setVertexBuffer(quadVertices, offset: 0, index: VertexInputIndex.vertices.rawValue)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<StampPassUniforms>.stride,
                                   index: VertexInputIndex.uniforms.rawValue)
            // Offset selects this pass's slice of the shared buffer; instance_id then starts at 0.
            encoder.setVertexBuffer(instances, offset: first * MemoryLayout<StampInstance>.stride,
                                    index: VertexInputIndex.instances.rawValue)
            // Same uniforms for the fragment stage: it has its own buffer slots.
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StampPassUniforms>.stride,
                                     index: FragmentInputIndex.uniforms.rawValue)
            encoder.setFragmentTexture(style.shape, index: TextureIndex.shape.rawValue)
            encoder.setFragmentTexture(style.grain, index: TextureIndex.grain.rawValue)
            // All stamps in one call; blending still happens in instance order.
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            drawCalls = 1
        }
        encoder.endEncoding()
        return drawCalls
    }

    /// Stroke coverage -> canvas, once: paint adds color, eraser takes paint out.
    private func encodeMerge(into commandBuffer: MTLCommandBuffer) {
        let loadAction: MTLLoadAction = canvasNeedsClear ? .clear : .load
        let pipeline = strokeStyle?.mode == .erase ? eraseMergePipeline : compositePipeline
        encodeCanvasPass(into: commandBuffer, loadAction: loadAction, label: "Stroke merge") { encoder in
            // Same size textures: the quad covers the whole canvas.
            self.bindQuad(encoder, transform: matrix_identity_float3x3)
            // The predicted tail is never merged: by lift-off real samples have replaced it.
            self.encodeStrokeComposite(into: encoder, pipeline: pipeline)
        }
        strokeNeedsMerge = false
        isStrokeVisible = false
        isPredictionVisible = false
        strokeStyle = nil
    }

    private func bindQuad(_ encoder: MTLRenderCommandEncoder, transform: simd_float3x3) {
        encoder.setVertexBuffer(quadVertices, offset: 0, index: VertexInputIndex.vertices.rawValue)
        var quad = QuadUniforms(transform: transform)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride,
                               index: VertexInputIndex.uniforms.rawValue)
    }

    /// Expects the quad already bound.
    private func encodeStrokeComposite(into encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(strokeTexture, index: TextureIndex.image.rawValue)
        encoder.setFragmentBytes(&strokeComposite, length: MemoryLayout<StrokeCompositeUniforms>.stride,
                                 index: FragmentInputIndex.uniforms.rawValue)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeCanvasPass(into commandBuffer: MTLCommandBuffer, loadAction: MTLLoadAction,
                                  label: String, draw: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = label
        draw(encoder)
        encoder.endEncoding()
        canvasNeedsClear = false
    }

    /// Whole-texture GPU copy; ordered with the render passes of the same command buffer.
    private func encodeCopy(from source: MTLTexture, to destination: MTLTexture,
                            into commandBuffer: MTLCommandBuffer, label: String) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = label
        blit.copy(from: source, to: destination)
        blit.endEncoding()
    }

    private func checkpoint() -> MTLTexture {
        if let checkpointTexture {
            return checkpointTexture
        }
        let texture = Self.makeTexture(device: device, pixelFormat: texture.pixelFormat, label: "Undo checkpoint")
        checkpointTexture = texture
        return texture
    }

    // MARK: - Setup

    private static func makeTexture(device: MTLDevice, pixelFormat: MTLPixelFormat, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: pixelSize, height: pixelSize,
                                                                  mipmapped: false)
        // Rendered into, then sampled; GPU-only memory.
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Cannot allocate \(label) texture")
        }
        texture.label = label
        return texture
    }

    private static func makeQuadVertices(device: MTLDevice) -> MTLBuffer {
        // Triangle strip TL, TR, BL, BR -> triangles (TL, TR, BL) and (TR, BL, BR).
        // Clip-space y points up, texture v points down: top edge gets v = 0.
        let vertices = [
            Vertex(position: SIMD2(-1,  1), uv: SIMD2(0, 0)),
            Vertex(position: SIMD2( 1,  1), uv: SIMD2(1, 0)),
            Vertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
            Vertex(position: SIMD2( 1, -1), uv: SIMD2(1, 1)),
        ]
        guard let buffer = device.makeBuffer(bytes: vertices,
                                             length: MemoryLayout<Vertex>.stride * vertices.count) else {
            fatalError("Cannot allocate quad vertex buffer")
        }
        buffer.label = "Quad vertices"
        return buffer
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, label: String,
                                     vertex: String, fragment: String, pixelFormat: MTLPixelFormat,
                                     blending: (MTLRenderPipelineColorAttachmentDescriptor) -> Void)
                                     -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        // Must match the render target format, or validation fails.
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        blending(descriptor.colorAttachments[0])
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("\(label) pipeline: \(error)")
        }
    }
}
