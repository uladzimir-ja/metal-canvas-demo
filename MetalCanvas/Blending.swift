import Metal

extension MTLRenderPipelineColorAttachmentDescriptor {
    /// Source-over for premultiplied colors: result = src + dst * (1 - src.alpha).
    func enablePremultipliedAlphaBlending() {
        isBlendingEnabled = true
        rgbBlendOperation = .add
        alphaBlendOperation = .add
        sourceRGBBlendFactor = .one
        sourceAlphaBlendFactor = .one
        destinationRGBBlendFactor = .oneMinusSourceAlpha
        destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    /// Eraser: result = dst * (1 - src.alpha). Source color is ignored, existing paint is scaled down.
    func enableEraseBlending() {
        isBlendingEnabled = true
        rgbBlendOperation = .add
        alphaBlendOperation = .add
        sourceRGBBlendFactor = .zero
        sourceAlphaBlendFactor = .zero
        destinationRGBBlendFactor = .oneMinusSourceAlpha
        destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    /// result = max(src, dst): overlapping stamps never build up beyond the strongest one.
    /// Blend factors are ignored by the min/max operations.
    func enableMaxBlending() {
        isBlendingEnabled = true
        rgbBlendOperation = .max
        alphaBlendOperation = .max
    }
}
