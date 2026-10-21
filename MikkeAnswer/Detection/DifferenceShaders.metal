//
//  DifferenceShaders.metal
//  MikkeAnswer
//
//  間違い探し検出用の Metal コンピュートカーネル群。
//

#include <metal_stdlib>
using namespace metal;

static inline float luma(float3 c) {
    return dot(c, float3(0.299f, 0.587f, 0.114f));
}

static inline float lumaAt(texture2d<float, access::read> t, int2 p, int2 size) {
    p = clamp(p, int2(0), size - 1);
    return luma(t.read(uint2(p)).rgb);
}

// MARK: - 輝度勾配（Sobel）

kernel void gradientMagnitude(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(src.get_width(), src.get_height());
    if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;

    int2 p = int2(gid);
    float tl = lumaAt(src, p + int2(-1, -1), size);
    float t  = lumaAt(src, p + int2( 0, -1), size);
    float tr = lumaAt(src, p + int2( 1, -1), size);
    float l  = lumaAt(src, p + int2(-1,  0), size);
    float r  = lumaAt(src, p + int2( 1,  0), size);
    float bl = lumaAt(src, p + int2(-1,  1), size);
    float b  = lumaAt(src, p + int2( 0,  1), size);
    float br = lumaAt(src, p + int2( 1,  1), size);

    float gx = (tr + 2.0f * r + br) - (tl + 2.0f * l + bl);
    float gy = (bl + 2.0f * b + br) - (tl + 2.0f * t + tr);
    dst.write(float4(length(float2(gx, gy))), gid);
}

// MARK: - シフト探索（テンプレートマッチング）

struct ShiftParams {
    uint candidateCount;
    uint stride;
};

#define SHIFT_THREADS 256

// 1 スレッドグループ = (候補シフト, タイル) の 1 組。
// タイル内の a(p) と b(p + shift) の差の総和 Σ|a-b| と、テクスチャ量 Σ(a+b) を返す。
kernel void shiftScore(texture2d<float, access::read> a [[texture(0)]],
                       texture2d<float, access::read> b [[texture(1)]],
                       constant int4 *tiles [[buffer(0)]],
                       constant int2 *candidates [[buffer(1)]],
                       device float2 *scores [[buffer(2)]],
                       constant ShiftParams &params [[buffer(3)]],
                       uint2 group [[threadgroup_position_in_grid]],
                       uint tid [[thread_index_in_threadgroup]])
{
    threadgroup float2 partial[SHIFT_THREADS];

    int4 tile = tiles[group.y];
    int2 shift = candidates[group.x];
    int2 sizeA = int2(a.get_width(), a.get_height());
    int2 sizeB = int2(b.get_width(), b.get_height());

    int st = int(params.stride);
    int nx = (tile.z + st - 1) / st;
    int ny = (tile.w + st - 1) / st;
    int n = nx * ny;

    float2 acc = float2(0.0f);
    for (int i = int(tid); i < n; i += SHIFT_THREADS) {
        int2 p = tile.xy + int2(i % nx, i / nx) * st;
        int2 q = p + shift;
        if (any(p < 0) || any(p >= sizeA) || any(q < 0) || any(q >= sizeB)) continue;
        float va = a.read(uint2(p)).r;
        float vb = b.read(uint2(q)).r;
        acc += float2(abs(va - vb), va + vb);
    }

    partial[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = SHIFT_THREADS / 2; s > 0; s >>= 1) {
        if (tid < s) partial[tid] += partial[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        scores[group.y * params.candidateCount + group.x] = partial[0];
    }
}

// MARK: - 切り出し + 変位場によるワープ

struct WarpParams {
    float3 h0;          // A 側のソース座標 → B 側のソース座標への射影変換（行ベクトル）
    float3 h1;
    float3 h2;
    float3 affineX;     // 残りの変位 x = affineX · (x, y, 1)（作業画素）
    float3 affineY;     // 残りの変位 y = affineY · (x, y, 1)
    float2 origin;      // ソース画像上の領域原点（px）
    float2 scale;       // 作業画素 → ソース画素の倍率
    float2 sourceSize;  // ソース画像サイズ（px）
    float2 tileSize;    // 残差場 1 マスあたりの作業画素数
    uint2 fieldDims;    // 残差場のマス数
};

static inline float2 sampleField(constant float2 *field, uint2 dims, float2 pos) {
    float2 g = clamp(pos - 0.5f, float2(0.0f), float2(dims) - 1.0f);
    uint2 i0 = uint2(g);
    uint2 i1 = min(i0 + 1, dims - 1);
    float2 f = g - float2(i0);
    float2 v00 = field[i0.y * dims.x + i0.x];
    float2 v10 = field[i0.y * dims.x + i1.x];
    float2 v01 = field[i1.y * dims.x + i0.x];
    float2 v11 = field[i1.y * dims.x + i1.x];
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

kernel void warpCrop(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float2 *field [[buffer(0)]],
                     constant WarpParams &params [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 pos = float2(gid) + 0.5f;
    float3 h = float3(pos, 1.0f);
    float2 disp = float2(dot(params.affineX, h), dot(params.affineY, h))
                + sampleField(field, params.fieldDims, pos / params.tileSize);
    float3 a = float3(params.origin + (pos + disp) * params.scale, 1.0f);
    float3 q = float3(dot(params.h0, a), dot(params.h1, a), dot(params.h2, a));
    float2 srcPos = q.xy / q.z;
    dst.write(src.sample(s, srcPos / params.sourceSize), gid);
}

// MARK: - 色差

struct DifferenceParams {
    float3 gainPlane;   // B の明るさ補正倍率 = x·u + y·v + z（u, v は 0〜1 の正規化座標）
    int radius;
};

// 照明差を補正したうえで、近傍 (2r+1)^2 内の最小色差を双方向に取り、その大きい方を差分とする。
// 位置合わせの残差（数 px）による輪郭の誤検出を抑える。
kernel void colorDifference(texture2d<float, access::read> a [[texture(0)]],
                            texture2d<float, access::read> b [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant DifferenceParams &params [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    int2 size = int2(a.get_width(), a.get_height());
    if (any(int2(gid) >= size)) return;

    float2 uv = (float2(gid) + 0.5f) / float2(size);
    float gain = clamp(dot(params.gainPlane, float3(uv, 1.0f)), 0.5f, 2.0f);
    int radius = params.radius;

    float3 ca = a.read(gid).rgb;
    float3 cb = b.read(gid).rgb * gain;
    float dab = 1e9f;
    float dba = 1e9f;
    for (int oy = -radius; oy <= radius; ++oy) {
        for (int ox = -radius; ox <= radius; ++ox) {
            uint2 q = uint2(clamp(int2(gid) + int2(ox, oy), int2(0), size - 1));
            dab = min(dab, distance(ca, b.read(q).rgb * gain));
            dba = min(dba, distance(cb, a.read(q).rgb));
        }
    }
    dst.write(float4(max(dab, dba)), gid);
}

// MARK: - 二値化

struct ThresholdParams {
    float threshold;
    float noiseWeight;
    uint border;
};

// しきい値は max(threshold, noiseWeight × 周囲の差分の平均)。
// ボケや照明ムラで差分が全体的に高い部分だけしきい値が上がり、そこから浮き出た差分だけを残す。
kernel void thresholdMask(texture2d<float, access::read> diff [[texture(0)]],
                          texture2d<float, access::read> noise [[texture(1)]],
                          texture2d<float, access::write> mask [[texture(2)]],
                          constant ThresholdParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint w = diff.get_width();
    uint h = diff.get_height();
    if (gid.x >= w || gid.y >= h) return;

    bool inside = gid.x >= params.border && gid.y >= params.border
               && gid.x + params.border < w && gid.y + params.border < h;
    float limit = max(params.threshold, params.noiseWeight * noise.read(gid).r);
    float v = (inside && diff.read(gid).r >= limit) ? 1.0f : 0.0f;
    mask.write(float4(v), gid);
}
