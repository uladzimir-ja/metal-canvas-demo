import Foundation
import Observation

/// Bridge between the SwiftUI toolbar and the renderer.
/// Main-actor isolated by the project default, as SwiftUI reads it on the main actor.
@Observable
final class CanvasController {
    // Not UI data: excluded from observation tracking.
    @ObservationIgnored private weak var renderer: Renderer?

    /// Mirrors the renderer; the Pencil double tap can change it too.
    var tool = Tool.pencil {
        didSet {
            if renderer?.tool != tool {
                renderer?.tool = tool
            }
        }
    }
    /// Outline to trace; nil = free drawing.
    var traceShape: TraceTarget.Shape? {
        didSet {
            guard traceShape != oldValue else { return }
            traceResult = nil
            renderer?.setTraceTarget(traceShape)
        }
    }
    private(set) var traceResult: TraceEvaluator.Result?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var status = ""
    private(set) var isReplaying = false

    func attach(_ renderer: Renderer) {
        self.renderer = renderer
        renderer.onStateChange = { [weak self] in
            self?.syncFromRenderer()
        }
        renderer.onTraceResult = { [weak self] result in
            self?.traceResult = result
        }
        syncFromRenderer()
    }

    func undo() {
        renderer?.undo()
    }

    func redo() {
        renderer?.redo()
    }

    func resetZoom() {
        renderer?.resetZoom()
    }

    func clear() {
        renderer?.clearCanvas()
        status = "Cleared"
    }

    func save() {
        guard let renderer else { return }
        let recording = renderer.makeRecording()
        guard !recording.strokes.isEmpty else {
            status = "Nothing to save"
            return
        }
        do {
            let url = try RecordingStore.save(recording)
            status = "Saved \(recording.strokes.count) strokes: \(url.lastPathComponent)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    func replayLatest() {
        guard let renderer, !isReplaying else { return }
        let recording: StrokeRecording
        do {
            guard let latest = try RecordingStore.latest() else {
                status = "No recordings"
                return
            }
            recording = latest
        } catch {
            status = "Load failed: \(error.localizedDescription)"
            return
        }
        isReplaying = true
        status = "Replaying \(recording.strokes.count) strokes…"
        Task {
            await renderer.replay(recording)
            isReplaying = false
            status = "Replay finished"
        }
    }

    private func syncFromRenderer() {
        guard let renderer else { return }
        // Equatable values: the @Observable setter skips invalidation when nothing changed.
        tool = renderer.tool
        canUndo = renderer.canUndo
        canRedo = renderer.canRedo
    }
}
