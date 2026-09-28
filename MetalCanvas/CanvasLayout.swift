import CoreGraphics
import simd

/// Where the canvas is shown on screen (fit, zoom, pan); converts between view points and canvas pixels.
struct CanvasLayout {
    static let zoomRange: ClosedRange<Float> = 1...8 // relative to fit; below 1 the unmipmapped canvas aliases
    private static let visibleMargin: Float = 100    // drawable pixels of canvas that always stay on screen

    let canvasSize: SIMD2<Float>         // canvas pixels
    var drawableSize = SIMD2<Float>.zero // drawable pixels
    var contentScale: Float = 1          // drawable pixels per view point
    private(set) var zoom: Float = 1
    private(set) var pan = SIMD2<Float>.zero // drawable pixels, canvas center offset from drawable center

    var isValid: Bool {
        drawableSize.x > 0 && drawableSize.y > 0
    }

    /// Canvas pixels -> drawable pixels at zoom 1: 1:1, shrunk to fit if the canvas is larger.
    var fit: Float {
        guard isValid else { return 1 }
        return min(1, min(drawableSize.x / canvasSize.x, drawableSize.y / canvasSize.y))
    }

    /// Drawable pixels per canvas pixel.
    var scale: Float {
        fit * zoom
    }

    /// Top-left corner of the canvas in drawable pixels.
    var canvasOrigin: SIMD2<Float> {
        (drawableSize - canvasSize * scale) / 2 + pan
    }

    /// How many canvas pixels one view point covers at the current placement.
    var canvasPixelsPerPoint: Float {
        contentScale / scale
    }

    /// Quad space (-1...1, y up) -> clip space, as a 3x3 affine matrix for the vertex shader.
    ///
    /// Three steps, each a scale plus an offset:
    ///   quad q -> canvas pixel p = ((q.x + 1) W/2, (1 - q.y) H/2)
    ///   p -> drawable pixel d = origin + scale * p
    ///   d -> clip c = (2 d.x / Dw - 1, 1 - 2 d.y / Dh)
    /// Combined: c = a * q + b per axis.
    var quadTransform: simd_float3x3 {
        guard isValid else { return simd_float3x3(diagonal: .zero) }
        let size = canvasSize * scale                 // canvas size in drawable pixels
        let center = canvasOrigin + size / 2          // canvas center in drawable pixels
        let a = size / drawableSize
        let b = SIMD2(center.x / drawableSize.x * 2 - 1, 1 - center.y / drawableSize.y * 2)
        return simd_float3x3(columns: (SIMD3(a.x, 0, 0),
                                       SIMD3(0, a.y, 0),
                                       SIMD3(b.x, b.y, 1)))
    }

    /// Inverse of the on-screen placement: view points -> drawable pixels -> canvas pixels.
    func canvasPoint(fromViewPoint point: CGPoint) -> SIMD2<Float> {
        (SIMD2<Float>(point) * contentScale - canvasOrigin) / scale
    }

    /// Length in view points -> canvas pixels (e.g. brush size set in points).
    func canvasLength(fromViewLength length: Float) -> Float {
        length * canvasPixelsPerPoint
    }

    /// Scales around a view point: the canvas point under it stays under it.
    mutating func zoom(by factor: Float, around viewPoint: CGPoint) {
        guard isValid else { return }
        let anchor = canvasPoint(fromViewPoint: viewPoint)
        zoom = simd_clamp(zoom * factor, Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        // Solve origin + scale * anchor = drawable point for the new scale.
        let drawablePoint = SIMD2<Float>(viewPoint) * contentScale
        let origin = drawablePoint - anchor * scale
        pan = origin - (drawableSize - canvasSize * scale) / 2
        clampPan()
    }

    mutating func pan(by viewTranslation: CGPoint) {
        pan += SIMD2<Float>(viewTranslation) * contentScale
        clampPan()
    }

    mutating func resetZoom() {
        zoom = 1
        pan = .zero
    }

    /// Keeps at least a margin of the canvas on screen.
    private mutating func clampPan() {
        let limit = simd_max((drawableSize + canvasSize * scale) / 2 - Self.visibleMargin, .zero)
        pan = simd_clamp(pan, -limit, limit)
    }
}

extension SIMD2 where Scalar == Float {
    init(_ point: CGPoint) {
        self.init(Float(point.x), Float(point.y))
    }
}
