import MetalKit

/// MTKView that forwards touches to StrokeInput, handles canvas gestures and the Pencil double tap.
///
/// One finger or the Pencil draws. Two fingers pinch and pan (a finger stroke in progress is cancelled
/// by the gesture), two-finger tap undoes, three-finger tap redoes. Gestures ignore the Pencil,
/// so fingers can move the canvas while the Pencil draws.
final class CanvasView: MTKView {
    weak var renderer: Renderer? {
        didSet { strokeInput.delegate = renderer }
    }
    private let strokeInput = StrokeInput()

    func installInteractions() {
        // Off by default in MTKView: multi-finger gestures need every touch.
        isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3

        for recognizer in [pinch, pan, undoTap, redoTap] {
            // Fingers only: the Pencil always draws.
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let renderer else { return }
        strokeInput.touchesBegan(touches, with: event, in: self, layout: renderer.layout)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let renderer else { return }
        strokeInput.touchesMoved(touches, with: event, in: self, layout: renderer.layout)
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let renderer else { return }
        strokeInput.touchesEnded(touches, with: event, in: self, layout: renderer.layout)
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        strokeInput.touchesCancelled(touches, with: event)
        setNeedsDisplay()
    }

    // Pencil sends real force and tilt after the estimates; may arrive after touchesEnded.
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard let renderer else { return }
        strokeInput.touchesEstimatedPropertiesUpdated(touches, in: self, layout: renderer.layout)
        setNeedsDisplay()
    }

    // MARK: - Gestures

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        // Incremental: apply the change since the last callback, then reset.
        renderer?.zoom(by: Float(recognizer.scale), around: recognizer.location(in: self))
        recognizer.scale = 1
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        renderer?.pan(by: recognizer.translation(in: self))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleUndoTap() {
        guard strokeInput.yieldToFingerGesture() else { return }
        renderer?.undo()
    }

    @objc private func handleRedoTap() {
        guard strokeInput.yieldToFingerGesture() else { return }
        renderer?.redo()
    }

    private func handlePencilDoubleTap() {
        // Respect the user's system setting for the double tap.
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser, .switchPrevious:
            // With two tools, "previous" and "eraser" both mean toggling.
            renderer?.tool = renderer?.tool == .eraser ? .pencil : .eraser
        default:
            break // palettes etc.: nothing to show in this app
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension CanvasView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger pan work together: zoom and move in one gesture.
        let isTransform = { (recognizer: UIGestureRecognizer) in
            recognizer is UIPinchGestureRecognizer || recognizer is UIPanGestureRecognizer
        }
        return isTransform(gestureRecognizer) && isTransform(other)
    }
}

// MARK: - UIPencilInteractionDelegate

extension CanvasView: UIPencilInteractionDelegate {
    // iOS 17.0–17.4.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilDoubleTap()
    }

    // iOS 17.5+: replaces the method above (only this one is called when both exist).
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilDoubleTap()
    }
}
