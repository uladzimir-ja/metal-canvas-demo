import SwiftUI

struct ContentView: View {
    @State private var controller = CanvasController()

    var body: some View {
        MetalCanvasView(controller: controller)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                CanvasToolbar(controller: controller)
                    .padding()
            }
    }
}

/// Tool, trace target, undo/redo, zoom reset, and debug controls (clear, save strokes as JSON, replay).
struct CanvasToolbar: View {
    // @Bindable: $controller.tool is a key-path binding into the @Observable model.
    @Bindable var controller: CanvasController

    var body: some View {
        // Status and metrics sit below the buttons, so changing text never shifts them.
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $controller.tool) {
                    Label("Pencil", systemImage: "pencil").tag(Tool.pencil)
                    Label("Eraser", systemImage: "eraser").tag(Tool.eraser)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Picker("Trace", selection: $controller.traceShape) {
                    Text("Free").tag(TraceTarget.Shape?.none)
                    Label("Circle", systemImage: "circle").tag(TraceTarget.Shape?.some(.circle))
                    Label("Star", systemImage: "star").tag(TraceTarget.Shape?.some(.star))
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Group {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        controller.undo()
                    }
                    .disabled(!controller.canUndo)
                    Button("Redo", systemImage: "arrow.uturn.forward") {
                        controller.redo()
                    }
                    .disabled(!controller.canRedo)
                    Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") {
                        controller.resetZoom()
                    }
                    Button("Clear", systemImage: "trash") {
                        controller.clear()
                    }
                    Button("Save", systemImage: "square.and.arrow.down") {
                        controller.save()
                    }
                    Button("Replay", systemImage: "play") {
                        controller.replayLatest()
                    }
                    .disabled(controller.isReplaying)
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .padding(8)
            .background(.regularMaterial, in: Capsule())

            TraceMetricsView(result: controller.traceResult)

            Text(controller.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// "Accuracy 87% · Coverage 64%" while a target is set.
struct TraceMetricsView: View {
    let result: TraceEvaluator.Result?

    var body: some View {
        if let result {
            HStack(spacing: 16) {
                Text("Accuracy \(result.accuracy.map(Self.percent) ?? "–")")
                Text("Coverage \(Self.percent(result.coverage))")
            }
            .font(.title3.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private static func percent(_ value: Float) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

#Preview {
    ContentView()
}
