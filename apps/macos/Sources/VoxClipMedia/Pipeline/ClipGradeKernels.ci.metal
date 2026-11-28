// The clip grade's Core Image colour kernels (looks spec 2026-11-28, sections 5 and 6; design.md section 6.9): stage P
// (the Fix), stage T with the Amount mix over the Fix's output, and stage F (vignette and grain by output pixel). They are
// the per-pixel half of `ClipGradeRecipe` (VoxClipCore ClipGrade.swift), which computes every constant in double; the
// shared vectors in shared/fixtures/clip-render/clip-grade-cases.json are the truth both sides replay.
//
// Core Image kernel language in Metal, compiled with -fcikernel and linked with -cikernel by
// tools/looks/build_mac_kernels.py into ClipGradeKernelLibrary.swift. Edit this file, then run that script.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace {
    constant float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);

    float luma(float3 c) { return dot(c, lumaWeights); }

    // Above the knee 0.8, u = (z - 0.8)/0.2 becomes 0.8 + 0.2u/(1 + alpha u), so the channel's white lands on 1.
    float shoulder(float z, float on, float alpha) {
        if (on < 0.5 || z <= 0.8) return z;
        float u = (z - 0.8) / 0.2;
        return 0.8 + 0.2 * u / (1.0 + alpha * u);
    }

    // A five-knot curve's four segments in Horner form, t = 4v - i.
    float curve(float value, float4 s0, float4 s1, float4 s2, float4 s3) {
        float v = clamp(value, 0.0, 1.0);
        float i = min(3.0, floor(4.0 * v));
        float t = 4.0 * v - i;
        float4 c = i < 0.5 ? s0 : i < 1.5 ? s1 : i < 2.5 ? s2 : s3;
        return c.x + t * (c.y + t * (c.z + t * c.w));
    }

    // Stage T2: dull colours first, red-to-yellow hues spared by 60%, luma kept, never leaving 0...1.
    float3 vibrance(float3 y, float v) {
        float l = luma(y);
        float c = max(y.r, max(y.g, y.b)) - min(y.r, min(y.g, y.b));
        float skin = 0.0;
        if (y.r >= y.g && y.g >= y.b && c > 0.0) {
            float q = ((y.g - y.b) / c - 0.45) / 0.35;
            skin = max(0.0, 1.0 - q * q) * smoothstep(0.02, 0.10, c);
        }
        float weight = v >= 0.0 ? (1.0 - c) * (1.0 - c) * (1.0 - 0.6 * skin) : (0.5 + 0.5 * c) * (1.0 - 0.6 * skin);
        float k = 1.0 + v * weight;
        for (int channel = 0; channel < 3; channel++) {
            float d = y[channel] - l;
            if (d > 1e-6) k = min(k, (1.0 - l) / d);
            else if (d < -1e-6) k = min(k, l / -d);
        }
        return l + k * (y - l);
    }

    // Stage T1, then T2; T3 and T4 are the toning variant's; then T5.
    float3 toneStart(float3 y, float4 t0, float4 t1, float4 t2, float4 t3, float4 params, float4 flags) {
        if (flags.x > 0.5) {
            float l = luma(y);
            y += curve(l, t0, t1, t2, t3) - l;
        }
        if (flags.y > 0.5) y = vibrance(y, params.x);
        return y;
    }

    float4 toneEnd(float3 y, float4 f, float alpha, float4 params, float4 flags) {
        if (flags.z > 0.5) {
            float3 c = clamp(y, 0.0, 1.0);
            float3 lift = 1.0 - c;
            y = c + params.y * lift * lift * lift;
        }
        float3 g = clamp(y, 0.0, 1.0);
        // Amount: out = f + a(g - f); at a = 1 the look's output bit for bit.
        float3 out = params.z >= 1.0 ? g : f.rgb + params.z * (g - f.rgb);
        return float4(out, alpha);
    }

    // PCG (Jarzynski and Olano 2020), mod 2^32.
    uint pcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    int floorDiv(int q, int span) { return q >= 0 ? q / span : -((span - 1 - q) / span); }

    int cellValue(int i, int j, uint frameHash) {
        return int(pcg(uint(i) + pcg(uint(j) + frameHash)) >> 16u) - 32768;
    }
}

extern "C" { namespace coreimage {

    // Stage P: one gain per channel, then the shoulder on each channel the gain brightens. gains.rgb; on.rgb is 1 where a
    // channel has a shoulder; alphas.rgb its alpha.
    float4 clipGradeFix(sample_t s, float4 gains, float4 on, float4 alphas) {
        float3 z = gains.rgb * clamp(s.rgb, 0.0, 1.0);
        return float4(shoulder(z.r, on.r, alphas.r), shoulder(z.g, on.g, alphas.g), shoulder(z.b, on.b, alphas.b), s.a);
    }

    // Stage T and the mix, without preset curves or split toning: `graded` is the picture after the look and adjustments,
    // `fixed` the Fix's output f. params = (vibrance/100, 0.0015 fade, amount/100, 0); flags = (tone, vibrance, fade, 0).
    float4 clipGradeTone(sample_t graded, sample_t fixed, float4 t0, float4 t1, float4 t2, float4 t3, float4 params, float4 flags) {
        float3 y = toneStart(clamp(graded.rgb, 0.0, 1.0), t0, t1, t2, t3, params, flags);
        return toneEnd(y, fixed, graded.a, params, flags);
    }

    // The same with a preset's curves (master on every channel, then red, green and blue; cf = which are present) and
    // split toning (shadow.rgb and highlight.rgb pre-scaled, shadow.w the balance offset; flags.w = split toning on).
    float4 clipGradeToning(sample_t graded, sample_t fixed, float4 t0, float4 t1, float4 t2, float4 t3, float4 params, float4 flags,
                           float4 m0, float4 m1, float4 m2, float4 m3, float4 r0, float4 r1, float4 r2, float4 r3,
                           float4 g0, float4 g1, float4 g2, float4 g3, float4 b0, float4 b1, float4 b2, float4 b3,
                           float4 cf, float4 shadow, float4 highlight) {
        float3 y = toneStart(clamp(graded.rgb, 0.0, 1.0), t0, t1, t2, t3, params, flags);
        if (cf.x > 0.5) y = float3(curve(y.r, m0, m1, m2, m3), curve(y.g, m0, m1, m2, m3), curve(y.b, m0, m1, m2, m3));
        if (cf.y > 0.5) y.r = curve(y.r, r0, r1, r2, r3);
        if (cf.z > 0.5) y.g = curve(y.g, g0, g1, g2, g3);
        if (cf.w > 0.5) y.b = curve(y.b, b0, b1, b2, b3);
        if (flags.w > 0.5) {
            float t = clamp(luma(y) + shadow.w, 0.0, 1.0);
            y += (1.0 - t) * (1.0 - t) * shadow.rgb + t * t * highlight.rgb;
        }
        return toneEnd(y, fixed, graded.a, params, flags);
    }

    // Stage F on the output frame: the vignette, then grain unless the pixel's centre lies in the context demo's hole.
    // frame = (W, H, 0.006 vignette a, 0.0012 grain a); grain = (cell size, hash >> 16, hash & 0xFFFF, 0);
    // hole = (minX, minY, maxX, maxY) from the top left. Rows count from the top: Core Image's origin is the bottom left.
    float4 clipGradeFinish(sample_t s, float4 frame, float4 grain, float4 hole, destination dest) {
        float3 value = clamp(s.rgb, 0.0, 1.0);
        int width = int(frame.x), height = int(frame.y);
        float2 coord = dest.coord();
        int x = int(floor(coord.x)), y = height - 1 - int(floor(coord.y));
        if (frame.z > 0.0) {
            float w = frame.x, h = frame.y;
            float nx = float(2 * x + 1 - width) / w, ny = float(2 * y + 1 - height) / h;
            float q = (nx * nx * w + ny * ny * h) / (w + h);
            float t = clamp((q - 0.16) / 0.84, 0.0, 1.0);
            value *= 1.0 - frame.z * (t * t * (3.0 - 2.0 * t));
        }
        float cx = float(x) + 0.5, cy = float(y) + 0.5;
        bool inHole = hole.x <= cx && cx < hole.z && hole.y <= cy && cy < hole.w;
        if (frame.w > 0.0 && !inHole) {
            int size = int(grain.x), span = 2 * size;
            uint frameHash = (uint(grain.y) << 16u) | uint(grain.z);
            int qx = 2 * x + 1 - size, qy = 2 * y + 1 - size;
            int i0 = floorDiv(qx, span), j0 = floorDiv(qy, span);
            int fx = 4 * (qx - span * i0) / span, fy = 4 * (qy - span * j0) / span;
            int a = i0 + 1, b = j0 + 1;
            int total = ((4 - fx) * cellValue(a, b, frameHash) + fx * cellValue(a + 1, b, frameHash)) * (4 - fy) +
                        ((4 - fx) * cellValue(a, b + 1, frameHash) + fx * cellValue(a + 1, b + 1, frameHash)) * fy;
            float l = luma(value);
            value += frame.w * (0.25 + 3.0 * l * (1.0 - l)) * (float(total) / 1048576.0);
        }
        return float4(value, s.a);
    }
}}
