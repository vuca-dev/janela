let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

constexpr sampler linearClamp(address::clamp_to_edge, filter::linear, coord::normalized);

struct StabilizerParams {
    float kStill;      // per-frame gain on still pixels
    float motionLo;    // luma delta where the filter begins to open
    float motionHi;    // luma delta where the filter is fully open
    float errorLo;     // matte delta where the filter begins to open
    float errorHi;     // matte delta where the filter is fully open
    float first;       // 1 on the first frame: seed the history
};

struct CompositeParams {
    float bgMix;       // 0 = bgA, 1 = bgB
    float lo;          // alpha below this is fully background
    float hi;          // alpha above this is fully foreground
    uint  frame;       // dither seed
    uint  showMatte;   // debug output
};

inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// 4x4 box downsample of the (linear-read) source into a quarter-size luma plane.
kernel void lumaDownsample(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 d = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(linearClamp, uv + d * float2(-1, -1)).rgb
             + src.sample(linearClamp, uv + d * float2( 1, -1)).rgb
             + src.sample(linearClamp, uv + d * float2(-1,  1)).rgb
             + src.sample(linearClamp, uv + d * float2( 1,  1)).rgb;
    // Motion thresholds are defined in display-referred units.
    dst.write(float4(pow(max(luminance(c * 0.25), 0.0), 1.0 / 2.2)), gid);
}

// 3x3 tent blur to suppress sensor noise.
kernel void lumaBlur(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int2 m = int2(src.get_width() - 1, src.get_height() - 1);
    float s = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float w = (2 - abs(x)) * (2 - abs(y));
        s += w * src.read(uint2(clamp(int2(gid) + int2(x, y), int2(0), m))).r;
    }
    dst.write(float4(s / 16.0), gid);
}

// Frame difference with a 3x3 max so the gate opens slightly ahead of moving edges.
kernel void motionField(texture2d<float, access::read> cur [[texture(0)]],
                        texture2d<float, access::read> prev [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 m = int2(cur.get_width() - 1, cur.get_height() - 1);
    float v = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        uint2 p = uint2(clamp(int2(gid) + int2(x, y), int2(0), m));
        v = max(v, abs(cur.read(p).r - prev.read(p).r));
    }
    dst.write(float4(v), gid);
}

// Motion-gated temporal filter on the matte. Heavy smoothing where the scene is
// still and the matte only jitters; wide open where anything actually moved.
kernel void stabilize(texture2d<float, access::sample> pha [[texture(0)]],
                      texture2d<float, access::read> hist [[texture(1)]],
                      texture2d<float, access::sample> motion [[texture(2)]],
                      texture2d<float, access::write> out [[texture(3)]],
                      constant StabilizerParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
    float a = pha.sample(linearClamp, uv).r;
    if (p.first > 0.5) { out.write(float4(a), gid); return; }
    float prev = hist.read(gid).r;
    float mo = smoothstep(p.motionLo, p.motionHi, motion.sample(linearClamp, uv).r);
    float er = saturate((abs(a - prev) - p.errorLo) / (p.errorHi - p.errorLo));
    float k = mix(p.kStill, 1.0, max(mo, er));
    out.write(float4(prev + k * (a - prev)), gid);
}

inline float3 oetf(float3 c) {
    return select(1.055 * pow(max(c, 1e-5), 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
}

// Interleaved gradient noise: decorrelates banding before the meeting app's H.264.
inline float ign(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }

// Compositing happens in linear light. Sources are sampled through _srgb views.
kernel void composite(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::sample> fgr [[texture(1)]],
                      texture2d<float, access::read> alpha [[texture(2)]],
                      texture2d<float, access::read> bgA [[texture(3)]],
                      texture2d<float, access::read> bgB [[texture(4)]],
                      texture2d<float, access::write> out [[texture(5)]],
                      constant CompositeParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // Choke the matte inward: the outer soft band holds the old room's colour.
    float a = saturate((alpha.read(gid).r - p.lo) / (p.hi - p.lo));
    if (p.showMatte != 0) { out.write(float4(float3(a), 1), gid); return; }
    float3 bg = mix(bgA.read(gid).rgb, bgB.read(gid).rgb, p.bgMix);
    float3 c;
    if (a >= 1.0) {
        c = src.read(gid).rgb;                       // full camera detail
    } else if (a <= 0.0) {
        c = bg;
    } else {
        // The model's foreground removes the old room's colour from soft edges.
        float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
        float3 f = mix(fgr.sample(linearClamp, uv).rgb, src.read(gid).rgb, smoothstep(0.96, 1.0, a));
        c = f * a + bg * (1.0 - a);
    }
    float3 e = oetf(saturate(c));
    float n = (ign(float2(gid) + float(p.frame % 64) * 5.588238) - 0.5) / 255.0;
    out.write(float4(saturate(e + n), 1), gid);
}
"""#
