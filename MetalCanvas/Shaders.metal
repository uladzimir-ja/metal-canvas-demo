#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// Vertex shader output, interpolated across the triangle for the fragment shader.
struct QuadOut {
    float4 position [[position]]; // clip space
    float2 uv;
};

vertex QuadOut quadVertex(uint vertexID [[vertex_id]],
                          constant Vertex *vertices [[buffer(VertexInputIndexVertices)]],
                          constant QuadUniforms &uniforms [[buffer(VertexInputIndexUniforms)]]) {
    QuadOut out;
    // Homogeneous 2D point (x, y, 1): the third column of the matrix holds the translation.
    float3 position = uniforms.transform * float3(vertices[vertexID].position, 1.0);
    out.position = float4(position.xy, 0.0, 1.0);
    out.uv = vertices[vertexID].uv;
    return out;
}

fragment float4 quadFragment(QuadOut in [[stage_in]],
                             texture2d<float> image [[texture(TextureIndexImage)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    return image.sample(linearClamp, in.uv);
}

// MARK: - Stamps

struct StampOut {
    float4 position [[position]]; // canvas clip space
    float2 uv;                    // 0...1 across the stamp, rotates with it
    float2 canvasPixel;           // for grain fixed to the canvas
    float alpha [[flat]];         // same for all fragments, no interpolation
};

// Instanced: the same 4 quad vertices are drawn once per stamp; instance_id selects the stamp.
vertex StampOut stampVertex(uint vertexID [[vertex_id]],
                            uint instanceID [[instance_id]],
                            constant Vertex *vertices [[buffer(VertexInputIndexVertices)]],
                            constant StampPassUniforms &pass [[buffer(VertexInputIndexUniforms)]],
                            const device StampInstance *stamps [[buffer(VertexInputIndexInstances)]]) {
    StampInstance stamp = stamps[instanceID];
    float2 corner = vertices[vertexID].position;
    // Rotate the quad geometry; UVs stay, so the shape texture turns with it.
    float s = sin(stamp.rotation);
    float c = cos(stamp.rotation);
    float2 rotated = float2(c * corner.x - s * corner.y, s * corner.x + c * corner.y);
    float2 pixel = stamp.center + rotated * stamp.radius;
    // Canvas pixels (y down) -> clip space (y up).
    float2 clip = pixel / pass.canvasSize * 2.0 - 1.0;
    clip.y = -clip.y;

    StampOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.uv = vertices[vertexID].uv;
    out.canvasPixel = pixel;
    out.alpha = stamp.alpha;
    return out;
}

// Coverage of one stamp, written into the single-channel stroke texture (only .r is stored).
// Pencil model: graphite only reaches paper bumps higher than a level set by pressure (and by the
// shape falloff at the edge). Light touch -> sparse specks on bump tops, hard press -> almost solid.
fragment float4 stampFragment(StampOut in [[stage_in]],
                              constant StampPassUniforms &pass [[buffer(FragmentInputIndexUniforms)]],
                              texture2d<float> shape [[texture(TextureIndexShape)]],
                              texture2d<float> grain [[texture(TextureIndexGrain)]]) {
    // Mip filtering: stamps are much smaller than the 128 px shape, mips prevent a flickering edge.
    constexpr sampler shapeSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // Grain tiles over the canvas; the texture is generated seamless.
    constexpr sampler grainSampler(filter::linear, address::repeat);

    float shapeValue = shape.sample(shapeSampler, in.uv).r;
    float2 grainSize = float2(grain.get_width(), grain.get_height());
    float2 grainUV = pass.grainSpace == GRAIN_SPACE_CANVAS
        ? in.canvasPixel / (grainSize * pass.grainScale)
        : in.uv;
    float height = grain.sample(grainSampler, grainUV).r; // uniform 0...1 paper height

    float amount = shapeValue * in.alpha;
    // Bump is covered when it is above 1 - amount; heights are uniform, so on average coverage = amount.
    constexpr float softness = 0.15; // soft band instead of a hard step: specks fade, not cut out
    float level = 1.0 - amount;
    float tooth = smoothstep(level - softness, level + softness, height) * step(0.001, amount);
    float coverage = mix(amount, tooth, pass.grainStrength);
    // Same value in alpha: "over" blending uses it as the source alpha.
    return float4(coverage);
}

// MARK: - Stroke composite

// Coverage x stroke color x opacity, premultiplied. Used for the live preview and the final merge.
fragment float4 strokeCompositeFragment(QuadOut in [[stage_in]],
                                        texture2d<float> coverage [[texture(TextureIndexImage)]],
                                        constant StrokeCompositeUniforms &stroke [[buffer(FragmentInputIndexUniforms)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float alpha = coverage.sample(linearClamp, in.uv).r * stroke.color.a;
    return float4(stroke.color.rgb * alpha, alpha);
}

// Screen preview while predicted touches exist: stroke plus the throw-away predicted tail.
// max() joins them seamlessly; blending two layers would darken the overlap.
fragment float4 strokePreviewFragment(QuadOut in [[stage_in]],
                                      texture2d<float> coverage [[texture(TextureIndexImage)]],
                                      texture2d<float> prediction [[texture(TextureIndexPrediction)]],
                                      constant StrokeCompositeUniforms &stroke [[buffer(FragmentInputIndexUniforms)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float combined = max(coverage.sample(linearClamp, in.uv).r, prediction.sample(linearClamp, in.uv).r);
    float alpha = combined * stroke.color.a;
    return float4(stroke.color.rgb * alpha, alpha);
}

// MARK: - Trace: display

// Target outline under the canvas: a thin line plus a faint band showing the tolerance.
fragment float4 traceGuideFragment(QuadOut in [[stage_in]],
                                   texture2d<float> field [[texture(TextureIndexDistance)]],
                                   constant TraceUniforms &trace [[buffer(FragmentInputIndexUniforms)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float distance = field.sample(linearClamp, in.uv).r; // canvas pixels
    float line = 1.0 - smoothstep(trace.guideWidth - 1.0, trace.guideWidth + 1.0, distance);
    float band = 1.0 - smoothstep(trace.tolerance - 1.0, trace.tolerance + 1.0, distance);
    float alpha = max(line * 0.55, band * 0.07);
    float3 color = float3(0.35, 0.55, 0.85);
    return float4(color * alpha, alpha); // premultiplied
}

// Live stroke while tracing: green inside the tolerance, red outside.
fragment float4 strokeTracePreviewFragment(QuadOut in [[stage_in]],
                                           texture2d<float> coverage [[texture(TextureIndexImage)]],
                                           texture2d<float> prediction [[texture(TextureIndexPrediction)]],
                                           texture2d<float> field [[texture(TextureIndexDistance)]],
                                           constant StrokeCompositeUniforms &stroke [[buffer(FragmentInputIndexUniforms)]],
                                           constant TraceUniforms &trace [[buffer(FragmentInputIndexTrace)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float combined = max(coverage.sample(linearClamp, in.uv).r, prediction.sample(linearClamp, in.uv).r);
    float distance = field.sample(linearClamp, in.uv).r;
    float outside = smoothstep(trace.tolerance - 1.5, trace.tolerance + 1.5, distance);
    float3 color = mix(float3(0.15, 0.62, 0.30), float3(0.85, 0.20, 0.18), outside);
    float alpha = combined * stroke.color.a;
    return float4(color * alpha, alpha);
}

// MARK: - Trace: compute

// Distance from each field texel to the closed outline polyline (brute force over segments).
// Built once per target; the field is half the canvas resolution, values in canvas pixels.
kernel void distanceFieldKernel(uint2 gid [[thread_position_in_grid]],
                                texture2d<float, access::write> field [[texture(TextureIndexDistance)]],
                                constant float2 *points [[buffer(ComputeIndexPoints)]],
                                constant TraceUniforms &trace [[buffer(ComputeIndexUniforms)]]) {
    // Needed when whole threadgroups overshoot the grid (no non-uniform dispatch).
    if (gid.x >= field.get_width() || gid.y >= field.get_height()) return;

    float2 p = (float2(gid) + 0.5) * trace.canvasPerField;
    float best = INFINITY;
    for (int i = 0; i < trace.pointCount; i++) {
        float2 a = points[i];
        float2 b = points[(i + 1) % trace.pointCount];
        float2 ab = b - a;
        // Closest point on segment ab: project, clamp to the segment.
        float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
        best = min(best, distance(p, a + t * ab));
    }
    field.write(float4(best), gid);
}

// Accuracy: every canvas pixel with paint counts as drawn; within tolerance it also counts as accurate.
kernel void traceAccuracyKernel(uint2 gid [[thread_position_in_grid]],
                                texture2d<float, access::read> canvas [[texture(TextureIndexImage)]],
                                texture2d<float> field [[texture(TextureIndexDistance)]],
                                constant TraceUniforms &trace [[buffer(ComputeIndexUniforms)]],
                                device atomic_uint *counters [[buffer(ComputeIndexCounters)]]) {
    if (gid.x >= canvas.get_width() || gid.y >= canvas.get_height()) return;
    if (canvas.read(gid).a < trace.drawnAlpha) return;

    // Many threads add to the same counter: atomics keep every increment.
    atomic_fetch_add_explicit(&counters[TRACE_COUNTER_DRAWN], 1, memory_order_relaxed);
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(canvas.get_width(), canvas.get_height());
    if (field.sample(linearClamp, uv).r <= trace.tolerance) {
        atomic_fetch_add_explicit(&counters[TRACE_COUNTER_ACCURATE], 1, memory_order_relaxed);
    }
}

// Coverage: an outline sample is covered when paint exists within the search radius.
kernel void traceCoverageKernel(uint id [[thread_position_in_grid]],
                                texture2d<float, access::read> canvas [[texture(TextureIndexImage)]],
                                constant float2 *samples [[buffer(ComputeIndexPoints)]],
                                constant TraceUniforms &trace [[buffer(ComputeIndexUniforms)]],
                                device atomic_uint *counters [[buffer(ComputeIndexCounters)]]) {
    if (id >= uint(trace.pointCount)) return;

    int2 center = int2(samples[id]);
    int radius = int(trace.searchRadius);
    int2 size = int2(canvas.get_width(), canvas.get_height());
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 pixel = center + int2(dx, dy);
            if (dx * dx + dy * dy > radius * radius || any(pixel < 0) || any(pixel >= size)) continue;
            if (canvas.read(uint2(pixel)).a >= trace.drawnAlpha) {
                atomic_fetch_add_explicit(&counters[TRACE_COUNTER_COVERED], 1, memory_order_relaxed);
                return;
            }
        }
    }
}

// MARK: - Eraser

// Screen preview while erasing: the canvas with the eraser stroke (and its tail) taken out.
// Blending the eraser onto the screen would erase the paper too, so the canvas is reduced here.
fragment float4 canvasErasePreviewFragment(QuadOut in [[stage_in]],
                                           texture2d<float> canvas [[texture(TextureIndexImage)]],
                                           texture2d<float> coverage [[texture(TextureIndexCoverage)]],
                                           texture2d<float> prediction [[texture(TextureIndexPrediction)]],
                                           constant StrokeCompositeUniforms &stroke [[buffer(FragmentInputIndexUniforms)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float erase = max(coverage.sample(linearClamp, in.uv).r, prediction.sample(linearClamp, in.uv).r) * stroke.color.a;
    // Premultiplied: scaling all four channels removes paint without changing its color.
    return canvas.sample(linearClamp, in.uv) * (1.0 - erase);
}
