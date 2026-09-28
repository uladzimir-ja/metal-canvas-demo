import MetalKit

enum Tool: String, CaseIterable {
    case pencil
    case eraser
}

/// Owns the device and queue, turns strokes into stamps and drives the frame.
/// Live input, recording replay, undo and redo all go through the same stroke path.
final class Renderer: NSObject {
    // Experiments for the device: compare latency and smoothness with and without.
    /// Draw a throw-away tail from UIKit's predicted touches.
    private static let usePrediction = true
    /// Run MTKView's own 120 Hz loop while drawing instead of redrawing on touch events only.
    private static let renderContinuouslyWhileDrawing = false
    /// Undo redraws strokes from a canvas copy saved every this many strokes.
    private static let checkpointInterval = 20

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let canvas: Canvas
    private let traceEvaluator: TraceEvaluator
    private var needsTraceEvaluation = false
    /// New accuracy/coverage after the canvas changed; nil when no target is set.
    var onTraceResult: ((TraceEvaluator.Result?) -> Void)?
    private weak var view: MTKView?
    // Canvas placement on screen (fit, zoom, pan), updated on resize and gestures.
    private(set) var layout = CanvasLayout(canvasSize: SIMD2(repeating: Float(Canvas.pixelSize)))

    private let textures: BrushTextures
    private let pencilBrush: Brush
    private let eraserBrush: Brush
    private let strokeColor = SIMD3<Float>(0.28, 0.28, 0.30) // graphite gray, until a color picker exists

    /// Tool for the next live stroke; a stroke in progress keeps its brush.
    var tool = Tool.pencil {
        didSet { onStateChange?() }
    }
    /// Tool, undo or redo availability changed (also from gestures and the Pencil).
    var onStateChange: (() -> Void)?
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Current stroke.
    private var strokeProcessor: StrokeProcessor?
    private var strokeBrush: Brush?
    private var strokePixelsPerPoint: Float = 1 // frozen at stroke start: size must not jump mid-stroke
    private var currentRecord: RecordedStroke?

    // History: finished strokes, i.e. what is on the canvas, as input. Also the recording (Save).
    private var history: [RecordedStroke] = []
    private var redoStack: [RecordedStroke] = []
    private var checkpointStrokeCount: Int? // the checkpoint holds the canvas after this many strokes
    private(set) var isReplaying = false
    private var isRedrawing = false // undo/redo: no per-stroke logs

    // Diagnostics.
    private var stats = StrokeStats()
    private var strokeID = 0
    private var hasPendingReport = false
    private var lastStrokeFrameTime: CFTimeInterval?
    private var newestSampleTime: TimeInterval? // newest real touch not yet on screen
    private var lastMeasuredSampleTime: TimeInterval = 0

    init(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is not supported on this device")
        }
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Shaders.metal is not compiled into the app")
        }
        do {
            pencilBrush = try Brush.load(named: "pencil")
            eraserBrush = try Brush.load(named: "eraser")
        } catch {
            fatalError("Brush preset: \(error)")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.view = view
        textures = BrushTextures(device: device, commandQueue: commandQueue)

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1) // paper white
        // Redraw on demand only (setNeedsDisplay), not in a continuous loop.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120

        // Heavy objects: created once, reused every frame.
        canvas = Canvas(device: device, library: library, screenPixelFormat: view.colorPixelFormat)
        traceEvaluator = TraceEvaluator(device: device, library: library)
        super.init()

        // Generate the brushes' textures now rather than on the first stroke.
        _ = makeStyle(brush: pencilBrush, color: strokeColor)
        _ = makeStyle(brush: eraserBrush, color: strokeColor)

        // A12X is Apple5; newer features must be gated on family checks.
        print("GPU: \(device.name), Apple5: \(device.supportsFamily(.apple5))")
        print("Brushes: \(pencilBrush.id), \(eraserBrush.id)")
        print("Prediction: \(Self.usePrediction), continuous while drawing: \(Self.renderContinuouslyWhileDrawing)")

        view.delegate = self
    }

    // MARK: - Commands

    func clearCanvas() {
        guard strokeProcessor == nil, !isReplaying else { return }
        canvas.clear()
        history.removeAll()
        redoStack.removeAll()
        checkpointStrokeCount = nil
        needsTraceEvaluation = true
        view?.setNeedsDisplay()
        onStateChange?()
    }

    /// Shows a target outline to trace (nil hides it) and evaluates the canvas against it.
    func setTraceTarget(_ shape: TraceTarget.Shape?) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Distance field"
        traceEvaluator.setTarget(shape.map { TraceTarget($0, canvasSize: Float(Canvas.pixelSize)) },
                                 canvasSize: Canvas.pixelSize, commandBuffer: commandBuffer)
        // Same queue as the frames: the field is ready before any frame that samples it.
        commandBuffer.commit()
        needsTraceEvaluation = true
        view?.setNeedsDisplay()
    }

    /// Everything drawn since the last clear.
    func makeRecording() -> StrokeRecording {
        StrokeRecording(canvasSize: Canvas.pixelSize, strokes: history)
    }

    /// Feeds recorded samples through the stroke path at their original pace.
    func replay(_ recording: StrokeRecording) async {
        guard !isReplaying, strokeProcessor == nil else { return }
        isReplaying = true
        defer { isReplaying = false }

        let clock = ContinuousClock()
        for stroke in recording.strokes {
            beginStroke(brush: stroke.brush, color: stroke.color,
                        canvasPixelsPerPoint: stroke.canvasPixelsPerPoint, record: true)
            let start = clock.now
            for sample in stroke.samples {
                // Timestamps are relative to the stroke start: wait until each sample is due.
                try? await Task.sleep(until: start + .seconds(sample.timestamp), clock: clock)
                addSamples([sample])
                view?.setNeedsDisplay()
            }
            finishStroke()
            view?.setNeedsDisplay()
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Removes the last stroke: restore the checkpoint (or clear) and redraw the strokes after it.
    func undo() {
        guard strokeProcessor == nil, !isReplaying, let last = history.popLast() else { return }
        redoStack.append(last)
        // A pending merge (and checkpoint save) must reach the GPU before the canvas is restored.
        if canvas.strokeNeedsMerge {
            flushCanvas()
        }

        let start = CACurrentMediaTime()
        var first = 0
        if let checkpoint = checkpointStrokeCount, checkpoint <= history.count {
            canvas.restoreCheckpoint()
            first = checkpoint
        } else {
            // Undone past the checkpoint: rebuild from an empty canvas, saving new checkpoints on the way.
            canvas.clear()
            checkpointStrokeCount = nil
        }
        isRedrawing = true
        for index in first..<history.count {
            draw(history[index])
            saveCheckpointIfDue(strokeCount: index + 1)
        }
        isRedrawing = false
        flushCanvas()
        needsTraceEvaluation = true

        print(String(format: "Undo: restored %@, redrew %d strokes in %.1f ms",
                     first > 0 ? "checkpoint at \(first)" : "empty canvas",
                     history.count - first, (CACurrentMediaTime() - start) * 1000))
        view?.setNeedsDisplay()
        onStateChange?()
    }

    /// Draws the last undone stroke again: no redraw of the rest needed.
    func redo() {
        guard strokeProcessor == nil, !isReplaying, let stroke = redoStack.popLast() else { return }
        isRedrawing = true
        draw(stroke)
        isRedrawing = false
        history.append(stroke)
        saveCheckpointIfDue(strokeCount: history.count)
        view?.setNeedsDisplay()
        onStateChange?()
    }

    // MARK: - Zoom and pan

    func zoom(by factor: Float, around viewPoint: CGPoint) {
        layout.zoom(by: factor, around: viewPoint)
        view?.setNeedsDisplay()
    }

    func pan(by viewTranslation: CGPoint) {
        layout.pan(by: viewTranslation)
        view?.setNeedsDisplay()
    }

    func resetZoom() {
        layout.resetZoom()
        view?.setNeedsDisplay()
    }

    // MARK: - Stroke path (live, replay, undo/redo)

    /// A recorded stroke, drawn at once (no timing): used by undo and redo.
    private func draw(_ stroke: RecordedStroke) {
        beginStroke(brush: stroke.brush, color: stroke.color,
                    canvasPixelsPerPoint: stroke.canvasPixelsPerPoint, record: false)
        addSamples(stroke.samples)
        finishStroke()
    }

    private func beginStroke(brush: Brush, color: SIMD3<Float>, canvasPixelsPerPoint: Float, record: Bool) {
        // Previous stroke ended but no frame has merged it yet (quick taps, undo redraw): merge it now,
        // before the new stroke clears the stroke texture. Queue order keeps it before the next frame.
        if canvas.strokeNeedsMerge {
            flushCanvas()
        }
        reportStats()

        strokeBrush = brush
        strokePixelsPerPoint = canvasPixelsPerPoint
        // Brush size is set in view points, so it looks the same at any canvas scale.
        strokeProcessor = StrokeProcessor(spacing: brush.spacing) { point in
            brush.diameter(for: point) * canvasPixelsPerPoint
        }
        canvas.beginStroke(style: makeStyle(brush: brush, color: color))
        currentRecord = record
            ? RecordedStroke(brush: brush, color: color, canvasPixelsPerPoint: canvasPixelsPerPoint, samples: [])
            : nil

        strokeID += 1
        stats = StrokeStats()
        lastStrokeFrameTime = nil
        if Self.renderContinuouslyWhileDrawing, !isRedrawing {
            view?.isPaused = false
        }
    }

    private func addSamples(_ samples: [InputSample]) {
        guard !samples.isEmpty else { return }
        var points: [StampPoint] = []
        for sample in samples {
            points += strokeProcessor?.add(sample) ?? []
        }
        addStamps(points)
        currentRecord?.samples += samples
    }

    private func finishStroke() {
        addStamps(strokeProcessor?.finish() ?? [])
        canvas.setPrediction([])
        canvas.endStroke()
        // Metrics are encoded right after the merge, in the same command buffer.
        needsTraceEvaluation = true
        if let currentRecord {
            // A new stroke makes the undone ones unreachable.
            history.append(currentRecord)
            redoStack.removeAll()
            saveCheckpointIfDue(strokeCount: history.count)
            onStateChange?()
        }
        resetStroke()
    }

    private func cancelStroke() {
        // Dropped strokes are not on the canvas, so they are not recorded either.
        canvas.cancelStroke()
        print("Stroke cancelled")
        resetStroke()
    }

    private func resetStroke() {
        strokeProcessor = nil
        strokeBrush = nil
        currentRecord = nil
        guard !isRedrawing else { return }
        if Self.renderContinuouslyWhileDrawing {
            view?.isPaused = true
        }
        // Last frames are presented a few ms later: report once their latency has arrived.
        hasPendingReport = true
        let strokeID = strokeID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.strokeID == strokeID else { return }
            self.reportStats()
        }
    }

    /// Every `checkpointInterval` strokes the canvas is copied, right after that stroke is merged.
    private func saveCheckpointIfDue(strokeCount: Int) {
        guard strokeCount % Self.checkpointInterval == 0, strokeCount > (checkpointStrokeCount ?? 0) else { return }
        canvas.saveCheckpoint()
        checkpointStrokeCount = strokeCount
    }

    private func addStamps(_ points: [StampPoint]) {
        for instance in makeInstances(points, firstIndex: stats.stamps) {
            canvas.add(instance)
        }
        stats.stamps += points.count
    }

    private func makeInstances(_ points: [StampPoint], firstIndex: Int) -> [StampInstance] {
        guard let strokeBrush else { return [] }
        return points.enumerated().map { offset, point in
            let diameter = strokeBrush.diameter(for: point) * strokePixelsPerPoint
            return StampInstance(center: point.position, radius: diameter / 2,
                                 alpha: strokeBrush.stampAlpha(for: point),
                                 rotation: strokeBrush.rotation(forStampIndex: firstIndex + offset))
        }
    }

    /// GPU-side brush description; textures are generated once per name and cached.
    private func makeStyle(brush: Brush, color: SIMD3<Float>) -> Canvas.StrokeStyle {
        let shape: MTLTexture
        let grain: MTLTexture
        do {
            shape = try textures.texture(named: brush.shape ?? "round_soft")
            grain = try brush.grain.map { try textures.texture(named: $0) } ?? textures.white
        } catch {
            fatalError("Brush \(brush.id) textures: \(error)")
        }
        return Canvas.StrokeStyle(
            mode: brush.effectiveMode,
            color: color,
            opacity: brush.opacity,
            blend: brush.stampBlend,
            shape: shape,
            grain: grain,
            grainScale: brush.grainScale ?? 1,
            grainStrength: brush.grain == nil ? 0 : brush.grainStrength ?? 1,
            grainSpace: brush.grainSpace ?? .canvas)
    }

    /// Encodes pending offscreen work right away, without waiting for the next frame.
    private func flushCanvas() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Canvas flush"
        canvas.encodeOffscreenPasses(into: commandBuffer)
        commandBuffer.commit()
    }

    private func reportStats() {
        guard hasPendingReport else { return }
        print(stats.report)
        hasPendingReport = false
    }
}

// MARK: - MTKViewDelegate

extension Renderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        print("Drawable size: \(size), scale: \(view.contentScaleFactor)")
        layout.drawableSize = SIMD2(Float(size.width), Float(size.height))
        layout.contentScale = Float(view.contentScaleFactor)
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame"

        // Frame pacing while drawing: time between consecutive frames.
        let now = CACurrentMediaTime()
        if strokeProcessor != nil {
            if let last = lastStrokeFrameTime {
                stats.addFrameInterval(now - last)
            }
            lastStrokeFrameTime = now
        }

        // Offscreen: stamps into the stroke and prediction textures, finished stroke into the canvas.
        let drawCalls = canvas.encodeOffscreenPasses(into: commandBuffer)
        if drawCalls > 0 {
            stats.addEncode(time: CACurrentMediaTime() - now, drawCalls: drawCalls)
        }
        // After the offscreen passes, so the kernels see the canvas with the latest merge.
        if needsTraceEvaluation, strokeProcessor == nil {
            needsTraceEvaluation = false
            if traceEvaluator.target != nil {
                traceEvaluator.encodeEvaluation(canvas: canvas.texture, into: commandBuffer) { [weak self] result in
                    self?.onTraceResult?(result)
                }
            } else {
                onTraceResult?(nil)
            }
        }

        // Screen: canvas plus stroke preview. Descriptor targets the drawable with loadAction = .clear.
        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            // No drawable (e.g. in background): still submit the offscreen work so it is not lost.
            commandBuffer.commit()
            return
        }
        encoder.label = "Screen"
        let trace = traceEvaluator.field.map { Canvas.TraceOverlay(field: $0, uniforms: traceEvaluator.uniforms) }
        canvas.encodeScreen(into: encoder, transform: layout.quadTransform, trace: trace)
        encoder.endEncoding()

        if let touchTime = newestSampleTime {
            newestSampleTime = nil
            measureLatency(from: touchTime, commandBuffer: commandBuffer, drawable: drawable)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Touch timestamps, presentedTime and CACurrentMediaTime all count seconds since boot: one clock.
    private func measureLatency(from touchTime: TimeInterval, commandBuffer: MTLCommandBuffer,
                                drawable: MTLDrawable) {
        let strokeID = strokeID
        let record: @Sendable (TimeInterval) -> Void = { [weak self] endTime in
            Task { @MainActor in
                guard let self, self.strokeID == strokeID else { return }
                self.stats.addLatency(endTime - touchTime)
            }
        }
        #if targetEnvironment(simulator)
        // The simulator SDK has no presented handler: measure until the GPU finishes (lower bound).
        commandBuffer.addCompletedHandler { @Sendable _ in
            record(CACurrentMediaTime())
        }
        #else
        // When the frame actually reached the display.
        drawable.addPresentedHandler { @Sendable presented in
            let presentedTime = presented.presentedTime
            guard presentedTime > 0 else { return } // 0 = frame was dropped
            record(presentedTime)
        }
        #endif
    }
}

// MARK: - StrokeInputDelegate

extension Renderer: StrokeInputDelegate {
    // Live touches are ignored while a recording replays through the same stroke path.

    func strokeInputDidBegin(_ input: StrokeInput) {
        guard !isReplaying else { return }
        let brush = tool == .eraser ? eraserBrush : pencilBrush
        beginStroke(brush: brush, color: strokeColor,
                    canvasPixelsPerPoint: layout.canvasPixelsPerPoint, record: true)
    }

    func strokeInput(_ input: StrokeInput, didCommit samples: [InputSample]) {
        // Final values: drawn once into the stroke texture.
        guard !isReplaying, strokeProcessor != nil else { return }
        addSamples(samples)
    }

    func strokeInput(_ input: StrokeInput, didUpdateTail pending: [InputSample], predicted: [InputSample]) {
        guard !isReplaying, var tail = strokeProcessor else { return }
        // A copy of the processor (it is a struct): extend it with the provisional samples and finish it.
        // The real processor is untouched; finish() also draws the last committed segment early.
        var points: [StampPoint] = []
        for sample in pending + (Self.usePrediction ? predicted : []) {
            points += tail.add(sample)
        }
        points += tail.finish()
        // Continue the stamp numbering, so jitter matches when real stamps replace the tail.
        canvas.setPrediction(makeInstances(points, firstIndex: stats.stamps))

        // The newest touch is on screen from this frame on (in the tail or committed).
        if input.lastTimestamp > lastMeasuredSampleTime {
            lastMeasuredSampleTime = input.lastTimestamp
            newestSampleTime = input.lastTimestamp
        }
        // Updates can arrive without a touch event: ask for a frame ourselves.
        view?.setNeedsDisplay()
    }

    func strokeInputDidEnd(_ input: StrokeInput) {
        guard !isReplaying, strokeProcessor != nil else { return }
        finishStroke()
    }

    func strokeInputDidCancel(_ input: StrokeInput) {
        guard !isReplaying, strokeProcessor != nil else { return }
        cancelStroke()
    }
}
