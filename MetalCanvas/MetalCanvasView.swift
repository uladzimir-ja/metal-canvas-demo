import SwiftUI
import MetalKit

/// Hosts the Metal canvas inside SwiftUI.
struct MetalCanvasView: UIViewRepresentable {
    let controller: CanvasController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView()
        // MTKView keeps a weak delegate, so the coordinator holds the renderer.
        let renderer = Renderer(view: view)
        context.coordinator.renderer = renderer
        view.renderer = renderer
        view.installInteractions()
        controller.attach(renderer)
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {}

    final class Coordinator {
        var renderer: Renderer?
    }
}
