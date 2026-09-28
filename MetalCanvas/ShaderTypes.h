// Types shared between Swift and Metal shaders.
// Included by Shaders.metal and used as the Swift bridging header.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
// MSL has no Foundation: define NS_ENUM as a plain typed enum.
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

// Buffer slots for vertex shaders.
typedef NS_ENUM(EnumBackingType, VertexInputIndex) {
    VertexInputIndexVertices = 0,
    VertexInputIndexUniforms = 1,
    VertexInputIndexInstances = 2,
};

// Buffer slots for fragment shaders (separate from vertex slots).
typedef NS_ENUM(EnumBackingType, FragmentInputIndex) {
    FragmentInputIndexUniforms = 0,
    FragmentInputIndexTrace = 1,
};

// Texture slots for fragment shaders.
typedef NS_ENUM(EnumBackingType, TextureIndex) {
    TextureIndexImage = 0,
    TextureIndexShape = 1,
    TextureIndexGrain = 2,
    TextureIndexPrediction = 3,
    TextureIndexCoverage = 4,
    TextureIndexDistance = 5,
};

// Buffer slots for compute kernels.
typedef NS_ENUM(EnumBackingType, ComputeIndex) {
    ComputeIndexUniforms = 0,
    ComputeIndexPoints = 1,
    ComputeIndexCounters = 2,
};

// Trace evaluation counters: a buffer of uints, used as atomic_uint in the kernels.
#define TRACE_COUNTER_DRAWN 0     // canvas pixels with paint
#define TRACE_COUNTER_ACCURATE 1  // ...of them within tolerance of the outline
#define TRACE_COUNTER_COVERED 2   // outline samples with paint nearby
#define TRACE_COUNTER_COUNT 3

// Target outline check (compute kernels and the on-screen guide/highlight).
typedef struct {
    float tolerance;      // canvas pixels: allowed distance from the outline
    float canvasPerField; // canvas pixels per distance field texel
    float drawnAlpha;     // canvas alpha from which a pixel counts as drawn
    float searchRadius;   // canvas pixels around an outline sample to look for paint
    int pointCount;       // outline vertices (distance field) or samples (coverage)
    float guideWidth;     // canvas pixels: half width of the guide line on screen
} TraceUniforms;

// Quad vertex: position in -1...1 (y up) and texture coordinate.
typedef struct {
    simd_float2 position;
    simd_float2 uv;
} Vertex;

// Per-draw quad parameters.
typedef struct {
    // Affine 2D transform, quad space -> clip space (zoom, pan, aspect, 1:1 pixels).
    // Three float3 columns, each padded to 16 bytes: same layout in C and MSL.
    simd_float3x3 transform;
} QuadUniforms;

// One brush stamp, an element of the instance buffer (20 bytes, stride 24).
// Only coverage goes into the stroke texture; color is applied once when the stroke is composited.
typedef struct {
    simd_float2 center; // canvas pixels, origin top-left
    float radius;       // canvas pixels
    float alpha;        // stamp coverage 0...1 (flow and pressure)
    float rotation;     // radians
} StampInstance;

// Where grain is read from: fixed on the canvas (paper) or moving with each stamp.
#define GRAIN_SPACE_CANVAS 0
#define GRAIN_SPACE_STAMP 1

// Shared by all stamps of one pass (vertex and fragment stages).
typedef struct {
    simd_float2 canvasSize; // canvas pixels
    float grainScale;       // canvas pixels per grain texel
    float grainStrength;    // 0 = no grain, 1 = grain fully modulates coverage
    int grainSpace;         // GRAIN_SPACE_*; plain int: 32-bit in both C and MSL
} StampPassUniforms;

// Stroke coverage -> color when compositing onto the canvas or the screen.
typedef struct {
    simd_float4 color; // straight RGB; alpha = stroke opacity
} StrokeCompositeUniforms;

#endif /* ShaderTypes_h */
