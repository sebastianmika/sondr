import Foundation

/// Metal Shading Language source for the embedding kernels. Compiled at runtime
/// (`device.makeLibrary(source:)`) so the library has no build-time dependency
/// on the offline Metal toolchain.
///
/// Pipeline per gradient-descent iteration:
///   1. `tsne_clear_scalar`   — zero the global normalization accumulator Z.
///   2. `tsne_repulsive`      — tiled O(N²) N-body pass: per-point repulsive
///                              force Σ_j q̃² (yᵢ-yⱼ) and partial Z = Σ_j q̃.
///   3. `tsne_attractive`     — sparse pass over the symmetric KNN graph:
///                              per-point attractive force Σ_j Pᵢⱼ q̃ (yᵢ-yⱼ).
///   4. `tsne_apply`          — combine into the gradient, adaptive gains +
///                              momentum update, advance positions.
///
/// q̃ᵢⱼ = 1/(1+‖yᵢ-yⱼ‖²) is the unnormalized Student-t affinity.
enum MetalShaders {
    static let source = """
#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

// ---------------------------------------------------------------------------
// K-nearest-neighbors: tiled brute force.
// One thread per query point. Candidate points are streamed through threadgroup
// memory one tile at a time so each is read from device memory only once per
// threadgroup. The per-query top-k list lives in the output buffers; we track
// the current worst (max) slot and replace it when a closer candidate appears.
// ---------------------------------------------------------------------------
struct KNNParams {
    uint n;     // number of points
    uint dim;   // dimensionality
    uint k;     // neighbors to keep
    uint tile;  // candidate tile size (elements)
};

kernel void knn_brute_force(
    device const float* data      [[buffer(0)]],   // n * dim, row-major
    device float*       outDist   [[buffer(1)]],   // n * k, squared distances
    device uint*        outIdx     [[buffer(2)]],   // n * k, neighbor indices
    constant KNNParams& p          [[buffer(3)]],
    threadgroup float*  tileBuf    [[threadgroup(0)]], // tile * dim floats
    uint gid                        [[thread_position_in_grid]],
    uint lid                        [[thread_position_in_threadgroup]],
    uint tgSize                     [[threads_per_threadgroup]])
{
    uint q = gid;
    bool active = q < p.n;
    uint qBase = q * p.dim;

    if (active) {
        for (uint j = 0; j < p.k; j++) {
            outDist[q * p.k + j] = FLT_MAX;
            outIdx[q * p.k + j] = q;
        }
    }

    float curMax = FLT_MAX;   // largest distance currently kept
    uint  curMaxPos = 0;      // its slot index in this query's row

    for (uint base = 0; base < p.n; base += p.tile) {
        uint tcount = min(p.tile, p.n - base);
        uint loadCount = tcount * p.dim;
        for (uint t = lid; t < loadCount; t += tgSize) {
            tileBuf[t] = data[base * p.dim + t];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (active) {
            for (uint c = 0; c < tcount; c++) {
                uint cand = base + c;
                if (cand == q) continue;
                float dist = 0.0;
                uint coff = c * p.dim;
                for (uint d = 0; d < p.dim; d++) {
                    float df = data[qBase + d] - tileBuf[coff + d];
                    dist += df * df;
                }
                if (dist < curMax) {
                    outDist[q * p.k + curMaxPos] = dist;
                    outIdx[q * p.k + curMaxPos] = cand;
                    // rescan row for the new worst slot
                    float m = -1.0; uint mp = 0;
                    for (uint j = 0; j < p.k; j++) {
                        float v = outDist[q * p.k + j];
                        if (v > m) { m = v; mp = j; }
                    }
                    curMax = m; curMaxPos = mp;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// ---------------------------------------------------------------------------
// Query KNN: nearest references for out-of-sample points.
// Same tiled brute force as above, but queries and references are distinct sets,
// so there is no self-match to skip. Used by `TSNEModel.transform`.
// ---------------------------------------------------------------------------
struct KNNQueryParams {
    uint m;     // number of query points
    uint n;     // number of reference points
    uint dim;
    uint k;
    uint tile;
};

kernel void knn_query(
    device const float* queries   [[buffer(0)]],   // m * dim, row-major
    device const float* refs      [[buffer(1)]],   // n * dim, row-major
    device float*       outDist   [[buffer(2)]],   // m * k, squared distances
    device uint*        outIdx    [[buffer(3)]],   // m * k, reference indices
    constant KNNQueryParams& p    [[buffer(4)]],
    threadgroup float*  tileBuf   [[threadgroup(0)]], // tile * dim floats
    uint gid                       [[thread_position_in_grid]],
    uint lid                       [[thread_position_in_threadgroup]],
    uint tgSize                    [[threads_per_threadgroup]])
{
    uint q = gid;
    bool active = q < p.m;
    uint qBase = q * p.dim;

    if (active) {
        for (uint j = 0; j < p.k; j++) {
            outDist[q * p.k + j] = FLT_MAX;
            outIdx[q * p.k + j] = 0;
        }
    }

    float curMax = FLT_MAX;
    uint  curMaxPos = 0;

    for (uint base = 0; base < p.n; base += p.tile) {
        uint tcount = min(p.tile, p.n - base);
        uint loadCount = tcount * p.dim;
        for (uint t = lid; t < loadCount; t += tgSize) {
            tileBuf[t] = refs[base * p.dim + t];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (active) {
            for (uint c = 0; c < tcount; c++) {
                float dist = 0.0;
                uint coff = c * p.dim;
                for (uint d = 0; d < p.dim; d++) {
                    float df = queries[qBase + d] - tileBuf[coff + d];
                    dist += df * df;
                }
                if (dist < curMax) {
                    outDist[q * p.k + curMaxPos] = dist;
                    outIdx[q * p.k + curMaxPos] = base + c;
                    float m = -1.0; uint mp = 0;
                    for (uint j = 0; j < p.k; j++) {
                        float v = outDist[q * p.k + j];
                        if (v > m) { m = v; mp = j; }
                    }
                    curMax = m; curMaxPos = mp;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// ---------------------------------------------------------------------------
// Query KNN, register-blocked. Same result as `knn_query`, several times faster.
//
// `knn_query` re-reads the query vector from device memory for every one of the
// N candidates, and walks the dimensions one scalar at a time — so the inner
// loop issues two loads per multiply-add and never approaches the machine's
// arithmetic throughput. Here instead:
//
//   * the query row is hoisted into registers once, as float4s;
//   * the reference tile is staged in threadgroup memory with its row stride
//     padded to a multiple of 4, so it can be read back as aligned float4s;
//   * the distance loop is float4 subtract + fma, a quarter of the iterations.
//
// The float4 count per row is a **function constant**, so each dimensionality
// gets its own specialization in which the loop bound is a compile-time constant
// and unrolls completely. That is what keeps `q` in registers: with a runtime
// bound the compiler must spill the array to thread-local memory, which is
// device-backed, and the whole point is lost.
//
// The top-k list stays in device memory exactly as in `knn_query`. It is touched
// only ~k·ln(N/k) times per query — a rounding error next to the N·dim distance
// work — so there is nothing to gain by moving it.
// ---------------------------------------------------------------------------
// The register array has to be sized at compile time, so it is sized for the
// largest supported dimension while the loop bound comes from the specialization.
// Sizing it at 32 float4s rather than 16 was measured to cost nothing at 32, 50 or
// 64 dimensions, so one kernel covers the whole range.
constant uint KNN_VEC [[function_constant(0)]];   // float4s per padded row
#define TSNE_KNN_MAX_VEC 32                       // ⇒ up to 128 dimensions

kernel void knn_query_blocked(
    device const float* queries    [[buffer(0)]],   // m * dim, row-major
    device const float* refs       [[buffer(1)]],   // n * dim, row-major
    device float*       outDist    [[buffer(2)]],   // m * k, squared distances
    device uint*        outIdx     [[buffer(3)]],   // m * k, reference indices
    constant KNNQueryParams& p     [[buffer(4)]],
    threadgroup float4* tile4      [[threadgroup(0)]], // tile * KNN_VEC float4s
    uint gid                        [[thread_position_in_grid]],
    uint lid                        [[thread_position_in_threadgroup]],
    uint tgSize                     [[threads_per_threadgroup]])
{
    uint q = gid;
    bool active = q < p.m;

    // Gather one row into registers, zero-padding the tail of the last float4.
    // Padding contributes (0 - 0)² = 0 to every distance.
    float4 qv[TSNE_KNN_MAX_VEC];
    if (active) {
        uint qBase = q * p.dim;
        for (uint v = 0; v < KNN_VEC; v++) {
            uint d0 = v * 4;
            float4 x = float4(0.0);
            uint rem = p.dim - d0;
            x.x = queries[qBase + d0];
            if (rem > 1) x.y = queries[qBase + d0 + 1];
            if (rem > 2) x.z = queries[qBase + d0 + 2];
            if (rem > 3) x.w = queries[qBase + d0 + 3];
            qv[v] = x;
        }
        for (uint j = 0; j < p.k; j++) {
            outDist[q * p.k + j] = FLT_MAX;
            outIdx[q * p.k + j] = 0;
        }
    }

    float curMax = FLT_MAX;
    uint  curMaxPos = 0;

    for (uint base = 0; base < p.n; base += p.tile) {
        uint tcount = min(p.tile, p.n - base);
        // Cooperative padded load. Amortized over every query in the
        // threadgroup, so the integer div/mod here costs nothing.
        for (uint t = lid; t < tcount * KNN_VEC; t += tgSize) {
            uint row = t / KNN_VEC;
            uint v = t - row * KNN_VEC;
            uint d0 = v * 4;
            uint rBase = (base + row) * p.dim;
            float4 x = float4(0.0);
            uint rem = p.dim - d0;
            x.x = refs[rBase + d0];
            if (rem > 1) x.y = refs[rBase + d0 + 1];
            if (rem > 2) x.z = refs[rBase + d0 + 2];
            if (rem > 3) x.w = refs[rBase + d0 + 3];
            tile4[t] = x;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (active) {
            for (uint c = 0; c < tcount; c++) {
                uint off = c * KNN_VEC;
                float4 acc = float4(0.0);
                for (uint v = 0; v < KNN_VEC; v++) {
                    float4 df = qv[v] - tile4[off + v];
                    acc = fma(df, df, acc);
                }
                float dist = acc.x + acc.y + acc.z + acc.w;
                if (dist < curMax) {
                    outDist[q * p.k + curMaxPos] = dist;
                    outIdx[q * p.k + curMaxPos] = base + c;
                    float mx = -1.0; uint mp = 0;
                    for (uint j = 0; j < p.k; j++) {
                        float v = outDist[q * p.k + j];
                        if (v > mx) { mx = v; mp = j; }
                    }
                    curMax = mx; curMaxPos = mp;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// ---------------------------------------------------------------------------
// Approximate KNN via NN-Descent.
// Instead of scanning all N candidates per point (the O(N²) cost), seed a random
// neighbor graph and refine it: each point pulls candidates from its neighbors'
// neighbors, which rapidly converges to the true KNN. Per round each point only
// evaluates k·sampleK candidates, so cost is ~O(N·k·sampleK) per round.
// ---------------------------------------------------------------------------
struct NNDParams {
    uint n;
    uint dim;
    uint k;
    uint sampleK; // neighbors-of-neighbor sampled per current neighbor
    uint seed;
};

// 64-bit SplitMix step.
inline ulong nnd_rand(thread ulong& s) {
    s += 0x9E3779B97F4A7C15UL;
    ulong z = s;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

kernel void nnd_init(
    device const float* data   [[buffer(0)]],
    device float*       dist    [[buffer(1)]],
    device uint*        idx      [[buffer(2)]],
    constant NNDParams& p        [[buffer(3)]],
    uint q                        [[thread_position_in_grid]])
{
    if (q >= p.n) return;
    ulong s = (ulong)p.seed ^ ((ulong)(q + 1) * 0x9E3779B97F4A7C15UL);
    for (uint t = 0; t < p.k; t++) {
        uint cand = (uint)(nnd_rand(s) % (ulong)p.n);
        if (cand == q) cand = (cand + 1 == p.n) ? 0u : cand + 1;
        float d = 0;
        for (uint dd = 0; dd < p.dim; dd++) { float df = data[q*p.dim+dd] - data[cand*p.dim+dd]; d += df*df; }
        dist[q * p.k + t] = d;
        idx[q * p.k + t] = cand;
    }
}

// One refinement round: read the snapshot graph (in*), write the improved row to
// (out*). Double-buffering keeps the exploration reading a stable graph.
kernel void nnd_step(
    device const float* data    [[buffer(0)]],
    device const float* inDist   [[buffer(1)]],
    device const uint*  inIdx    [[buffer(2)]],
    device float*       outDist  [[buffer(3)]],
    device uint*        outIdx   [[buffer(4)]],
    constant NNDParams& p        [[buffer(5)]],
    uint q                        [[thread_position_in_grid]])
{
    if (q >= p.n) return;
    float curMax = -1.0; uint curMaxPos = 0;
    for (uint t = 0; t < p.k; t++) {
        float v = inDist[q * p.k + t];
        outDist[q * p.k + t] = v;
        outIdx[q * p.k + t] = inIdx[q * p.k + t];
        if (v > curMax) { curMax = v; curMaxPos = t; }
    }
    ulong s = (ulong)p.seed ^ ((ulong)(q + 1) * 0xD1B54A32D192ED03UL);
    for (uint t = 0; t < p.k; t++) {
        uint j = inIdx[q * p.k + t];
        for (uint r = 0; r < p.sampleK; r++) {
            uint m = inIdx[j * p.k + (uint)(nnd_rand(s) % (ulong)p.k)];
            if (m == q) continue;
            bool present = false;
            for (uint c = 0; c < p.k; c++) { if (outIdx[q * p.k + c] == m) { present = true; break; } }
            if (present) continue;
            float d = 0;
            for (uint dd = 0; dd < p.dim; dd++) { float df = data[q*p.dim+dd] - data[m*p.dim+dd]; d += df*df; }
            if (d < curMax) {
                outDist[q * p.k + curMaxPos] = d;
                outIdx[q * p.k + curMaxPos] = m;
                float mm = -1.0; uint mp = 0;
                for (uint c = 0; c < p.k; c++) { float v = outDist[q * p.k + c]; if (v > mm) { mm = v; mp = c; } }
                curMax = mm; curMaxPos = mp;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Gradient descent kernels.
// ---------------------------------------------------------------------------
struct ApplyParams {
    uint  n;
    float learningRate;
    float momentum;
    float exaggeration;
    float minGain;
};

kernel void tsne_clear_scalar(
    device atomic_float* z [[buffer(0)]],
    uint gid                [[thread_position_in_grid]])
{
    if (gid == 0) atomic_store_explicit(z, 0.0, memory_order_relaxed);
}

// Tiled N-body repulsive pass. Each thread handles BODIES points to expose
// instruction-level parallelism (independent accumulation chains hide FP
// latency) and to reuse each threadgroup-cached candidate across several
// queries. For point i:
//   repForce[i] = Σ_{j} q̃ᵢⱼ² (yᵢ - yⱼ)        (self term contributes 0)
//   Z          += Σ_{j} q̃ᵢⱼ  − 1               (subtract the self pair q̃ᵢᵢ=1)
// Dropping the j==i test removes branch divergence from the hot loop.
#define BODIES 4

kernel void tsne_repulsive(
    device const float2* pos       [[buffer(0)]],
    device float2*       repForce  [[buffer(1)]],
    device atomic_float* zSum       [[buffer(2)]],
    constant uint&       n          [[buffer(3)]],
    threadgroup float2*  tile       [[threadgroup(0)]],
    threadgroup float*   scratch    [[threadgroup(1)]],
    uint gid                         [[thread_position_in_grid]],
    uint lid                         [[thread_position_in_threadgroup]],
    uint tgSize                      [[threads_per_threadgroup]])
{
    float2 yi[BODIES];
    float2 rep[BODIES];
    float  zi[BODIES];
    uint   idx[BODIES];
    for (uint b = 0; b < BODIES; b++) {
        idx[b] = gid * BODIES + b;
        yi[b] = (idx[b] < n) ? pos[idx[b]] : float2(0.0);
        rep[b] = float2(0.0);
        zi[b] = 0.0;
    }

    for (uint base = 0; base < n; base += tgSize) {
        uint tcount = min(tgSize, n - base);
        if (lid < tcount) tile[lid] = pos[base + lid];
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint c = 0; c < tcount; c++) {
            float2 yj = tile[c];
            for (uint b = 0; b < BODIES; b++) {
                float2 diff = yi[b] - yj;
                float q = 1.0 / (1.0 + dot(diff, diff)); // q̃ᵢⱼ (=1 when j==i)
                zi[b] += q;
                rep[b] += (q * q) * diff;                 // self term adds 0
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    float zLocal = 0.0;
    for (uint b = 0; b < BODIES; b++) {
        if (idx[b] < n) {
            repForce[idx[b]] = rep[b];
            zLocal += zi[b] - 1.0; // remove the self pair counted above
        }
    }

    // threadgroup reduction of the per-thread Z contribution
    scratch[lid] = zLocal;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tgSize / 2; s > 0; s >>= 1) {
        if (lid < s) scratch[lid] += scratch[lid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) atomic_fetch_add_explicit(zSum, scratch[0], memory_order_relaxed);
}

// Sparse attractive pass over the symmetric KNN graph (CSR layout).
kernel void tsne_attractive(
    device const float2* pos       [[buffer(0)]],
    device const float*  pVal       [[buffer(1)]],  // symmetric affinities
    device const uint*   colIdx     [[buffer(2)]],
    device const uint*   rowStart   [[buffer(3)]],
    device float2*       attrForce  [[buffer(4)]],
    constant uint&       n          [[buffer(5)]],
    uint gid                         [[thread_position_in_grid]])
{
    uint i = gid;
    if (i >= n) return;
    float2 yi = pos[i];
    uint start = rowStart[i];
    uint end = rowStart[i + 1];
    // 4-way unrolled accumulation: independent chains keep several scattered
    // pos[j] loads in flight, which hides memory latency on this gather-bound
    // pass (the dominant per-iteration cost at large N).
    float2 f0 = float2(0.0), f1 = float2(0.0), f2 = float2(0.0), f3 = float2(0.0);
    uint idx = start;
    for (; idx + 4 <= end; idx += 4) {
        float2 d0 = yi - pos[colIdx[idx + 0]];
        float2 d1 = yi - pos[colIdx[idx + 1]];
        float2 d2 = yi - pos[colIdx[idx + 2]];
        float2 d3 = yi - pos[colIdx[idx + 3]];
        f0 += (pVal[idx + 0] / (1.0 + dot(d0, d0))) * d0;
        f1 += (pVal[idx + 1] / (1.0 + dot(d1, d1))) * d1;
        f2 += (pVal[idx + 2] / (1.0 + dot(d2, d2))) * d2;
        f3 += (pVal[idx + 3] / (1.0 + dot(d3, d3))) * d3;
    }
    for (; idx < end; idx++) {
        float2 d = yi - pos[colIdx[idx]];
        f0 += (pVal[idx] / (1.0 + dot(d, d))) * d;
    }
    attrForce[i] = (f0 + f1) + (f2 + f3);
}

// Sparse attractive pass over the union of a base and guided affinity graph.
// `edgeValues.x` is the base value and `.y` is the guided value. Alpha is a
// single uniform parameter, so the endpoint branches do not diverge and retain
// the exact input values at zero and one.
inline float tsne_blended_affinity(float2 pair, float alpha) {
    if (alpha <= 0.0) return pair.x;
    if (alpha >= 1.0) return pair.y;
    return fma(alpha, pair.y - pair.x, pair.x);
}

kernel void tsne_attractive_blended(
    device const float2* pos         [[buffer(0)]],
    device const float2* edgeValues  [[buffer(1)]],
    device const uint*   colIdx      [[buffer(2)]],
    device const uint*   rowStart    [[buffer(3)]],
    device float2*       attrForce   [[buffer(4)]],
    constant uint&       n           [[buffer(5)]],
    constant float&      alpha       [[buffer(6)]],
    uint gid                           [[thread_position_in_grid]])
{
    uint i = gid;
    if (i >= n) return;
    float2 yi = pos[i];
    uint start = rowStart[i];
    uint end = rowStart[i + 1];
    float2 f0 = float2(0.0), f1 = float2(0.0), f2 = float2(0.0), f3 = float2(0.0);
    uint idx = start;
    for (; idx + 4 <= end; idx += 4) {
        float2 d0 = yi - pos[colIdx[idx + 0]];
        float2 d1 = yi - pos[colIdx[idx + 1]];
        float2 d2 = yi - pos[colIdx[idx + 2]];
        float2 d3 = yi - pos[colIdx[idx + 3]];
        float p0 = tsne_blended_affinity(edgeValues[idx + 0], alpha);
        float p1 = tsne_blended_affinity(edgeValues[idx + 1], alpha);
        float p2 = tsne_blended_affinity(edgeValues[idx + 2], alpha);
        float p3 = tsne_blended_affinity(edgeValues[idx + 3], alpha);
        f0 += (p0 / (1.0 + dot(d0, d0))) * d0;
        f1 += (p1 / (1.0 + dot(d1, d1))) * d1;
        f2 += (p2 / (1.0 + dot(d2, d2))) * d2;
        f3 += (p3 / (1.0 + dot(d3, d3))) * d3;
    }
    for (; idx < end; idx++) {
        float2 d = yi - pos[colIdx[idx]];
        float pValue = tsne_blended_affinity(edgeValues[idx], alpha);
        f0 += (pValue / (1.0 + dot(d, d))) * d;
    }
    attrForce[i] = (f0 + f1) + (f2 + f3);
}

struct InteractiveApplyParams {
    uint  n;
    float learningRate;
    float momentum;
    float exaggeration;
    float minGain;
    float priorStrengthOverN;
    float maximumStepNorm;
    uint  flags; // bit 0: clip enabled; bit 1: collect step metrics
};

kernel void tsne_clear_step_metrics(
    device atomic_float* squaredSum [[buffer(0)]],
    device atomic_uint*  maximumBits [[buffer(1)]],
    uint gid                           [[thread_position_in_grid]])
{
    if (gid != 0) return;
    atomic_store_explicit(squaredSum, 0.0, memory_order_relaxed);
    atomic_store_explicit(maximumBits, 0u, memory_order_relaxed);
}

struct ResetDynamicsParams {
    uint n;
    uint resetGains;
};

kernel void tsne_reset_dynamics(
    device float2* velocity            [[buffer(0)]],
    device float2* gains               [[buffer(1)]],
    constant ResetDynamicsParams& p    [[buffer(2)]],
    uint gid                            [[thread_position_in_grid]])
{
    if (gid >= p.n) return;
    velocity[gid] = float2(0.0);
    if (p.resetGains != 0) gains[gid] = float2(1.0);
}

// Session apply pass: the t-SNE KL gradient is augmented by the derivative of
// lambda/(2N) sum_i w_i ||y_i-t_i||^2. The final momentum update is clipped,
// then retained as velocity so a later step cannot reintroduce an oversized
// update through momentum.
kernel void tsne_apply_interactive(
    device float2*       pos             [[buffer(0)]],
    device float2*       vel             [[buffer(1)]],
    device float2*       gains           [[buffer(2)]],
    device const float2* attrForce       [[buffer(3)]],
    device const float2* repForce        [[buffer(4)]],
    device const float*  zSum            [[buffer(5)]],
    device const float2* priorTargets    [[buffer(6)]],
    device const float*  priorWeights    [[buffer(7)]],
    constant InteractiveApplyParams& p   [[buffer(8)]],
    device atomic_float* squaredStepSum  [[buffer(9)]],
    device atomic_uint*  maximumStepBits [[buffer(10)]],
    uint gid                              [[thread_position_in_grid]])
{
    uint i = gid;
    if (i >= p.n) return;
    float Z = max(zSum[0], 1e-12);
    float2 grad = 4.0 * (p.exaggeration * attrForce[i] - repForce[i] / Z);
    float priorWeight = priorWeights[i];
    if (p.priorStrengthOverN > 0.0 && priorWeight > 0.0) {
        grad += p.priorStrengthOverN * priorWeight * (pos[i] - priorTargets[i]);
    }

    float2 v = vel[i];
    float2 g = gains[i];
    g.x = (sign(grad.x) != sign(v.x)) ? (g.x + 0.2) : (g.x * 0.8);
    g.y = (sign(grad.y) != sign(v.y)) ? (g.y + 0.2) : (g.y * 0.8);
    g.x = max(g.x, p.minGain);
    g.y = max(g.y, p.minGain);

    v = p.momentum * v - p.learningRate * g * grad;
    float stepSquared = 0.0;
    float stepNorm = 0.0;
    if ((p.flags & 3u) != 0u) {
        stepSquared = dot(v, v);
        stepNorm = sqrt(stepSquared);
        if ((p.flags & 1u) != 0u && stepNorm > p.maximumStepNorm) {
            v *= p.maximumStepNorm / max(stepNorm, 1e-20);
            stepSquared = dot(v, v);
            stepNorm = sqrt(stepSquared);
        }
    }

    vel[i] = v;
    gains[i] = g;
    pos[i] += v;
    if ((p.flags & 2u) != 0u) {
        atomic_fetch_add_explicit(squaredStepSum, stepSquared, memory_order_relaxed);
        atomic_fetch_max_explicit(maximumStepBits, as_type<uint>(stepNorm), memory_order_relaxed);
    }
}

// Combine forces into the gradient and take an adaptive-gains + momentum step.
kernel void tsne_apply(
    device float2*       pos        [[buffer(0)]],
    device float2*       vel        [[buffer(1)]],
    device float2*       gains      [[buffer(2)]],
    device const float2* attrForce  [[buffer(3)]],
    device const float2* repForce   [[buffer(4)]],
    device const float*  zSum        [[buffer(5)]],
    constant ApplyParams& p          [[buffer(6)]],
    uint gid                         [[thread_position_in_grid]])
{
    uint i = gid;
    if (i >= p.n) return;
    float Z = max(zSum[0], 1e-12);
    // dC/dyᵢ = 4 ( Σ Pᵢⱼ q̃ (yᵢ-yⱼ)  -  (1/Z) Σ q̃² (yᵢ-yⱼ) )
    float2 grad = 4.0 * (p.exaggeration * attrForce[i] - repForce[i] / Z);

    float2 v = vel[i];
    float2 g = gains[i];
    // Jacobs' adaptive gains: grow where gradient & velocity agree, shrink else.
    g.x = (sign(grad.x) != sign(v.x)) ? (g.x + 0.2) : (g.x * 0.8);
    g.y = (sign(grad.y) != sign(v.y)) ? (g.y + 0.2) : (g.y * 0.8);
    g.x = max(g.x, p.minGain);
    g.y = max(g.y, p.minGain);

    v = p.momentum * v - p.learningRate * g * grad;
    vel[i] = v;
    gains[i] = g;
    pos[i] = pos[i] + v;
}

// ===========================================================================
// Field-splatting repulsion (linear-time alternative to the N-body pass).
//
// Splat a Student-t kernel at every point into an RGBA field, then sample it
// at each point. Field channels at offset δ (embedding units): R=t=1/(1+|δ|²),
// G=t²·δx, B=t²·δy. Summed over points then sampled at yᵢ gives
//   (Σⱼ t,  Σⱼ t²(yᵢ-yⱼ))  →  repForce=(G,B),  Z=Σᵢ(R-1).
// The embedding→field transform is recomputed on the GPU each iteration (a
// float4 {originX, originY, spacePerPixel, halfKernelPx}); the field resolution
// is fixed for the run so nothing needs reading back to the CPU.
// ===========================================================================

// Stage 1: per-threadgroup min/max of positions.
kernel void tsne_reduce_bounds_stage1(
    device const float2* pos        [[buffer(0)]],
    device float4*       partials   [[buffer(1)]],
    constant uint&       n          [[buffer(2)]],
    threadgroup float2*  sMin       [[threadgroup(0)]],
    threadgroup float2*  sMax       [[threadgroup(1)]],
    uint gid                         [[thread_position_in_grid]],
    uint lid                         [[thread_position_in_threadgroup]],
    uint tgid                        [[threadgroup_position_in_grid]],
    uint tgSize                      [[threads_per_threadgroup]])
{
    bool active = gid < n;
    float2 p = active ? pos[gid] : float2(0.0);
    sMin[lid] = active ? p : float2(FLT_MAX);
    sMax[lid] = active ? p : float2(-FLT_MAX);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tgSize / 2; s > 0; s >>= 1) {
        if (lid < s) {
            sMin[lid] = min(sMin[lid], sMin[lid + s]);
            sMax[lid] = max(sMax[lid], sMax[lid + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) partials[tgid] = float4(sMin[0].x, sMin[0].y, sMax[0].x, sMax[0].y);
}

// Stage 2: reduce all partials (single threadgroup) and emit the transform.
kernel void tsne_reduce_bounds_stage2(
    device const float4* partials    [[buffer(0)]],
    device float4*       outTransform [[buffer(1)]],
    constant uint&       numPartials [[buffer(2)]],
    constant uint&       res         [[buffer(3)]],
    threadgroup float4*  scratch     [[threadgroup(0)]],
    uint lid                          [[thread_position_in_threadgroup]],
    uint tgSize                       [[threads_per_threadgroup]])
{
    float2 mn = float2(FLT_MAX), mx = float2(-FLT_MAX);
    for (uint i = lid; i < numPartials; i += tgSize) {
        float4 pp = partials[i];
        mn = min(mn, float2(pp.x, pp.y));
        mx = max(mx, float2(pp.z, pp.w));
    }
    scratch[lid] = float4(mn.x, mn.y, mx.x, mx.y);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = tgSize / 2; s > 0; s >>= 1) {
        if (lid < s) {
            float4 a = scratch[lid], b = scratch[lid + s];
            scratch[lid] = float4(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) {
        float2 lo = float2(scratch[0].x, scratch[0].y);
        float2 hi = float2(scratch[0].z, scratch[0].w);
        float2 center = 0.5 * (lo + hi);
        const float kernelRadius = 2.5;   // kernel support, embedding units
        const float maxWindowPx = 5.0;    // bound the splat half-width in pixels
        float span = max(hi.x - lo.x, hi.y - lo.y) + 2.0 * kernelRadius;
        span = max(span, 1e-4);
        // Fill the fixed-resolution field, but floor spacePerPixel so the splat
        // window stays small even when the embedding is tiny (early iterations).
        float spp = max(span / float(res), kernelRadius / maxWindowPx);
        outTransform[0] = float4(center.x - 0.5 * float(res) * spp,
                                 center.y - 0.5 * float(res) * spp,
                                 spp,
                                 kernelRadius / spp);
    }
}

// Splat: one quad instance per point, additively blended into the field.
struct SplatVOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex SplatVOut splat_vertex(
    uint vid                       [[vertex_id]],
    uint iid                       [[instance_id]],
    device const float2* pos       [[buffer(0)]],
    constant float4&     xf         [[buffer(1)]],
    constant uint&       res        [[buffer(2)]])
{
    float2 origin = xf.xy;
    float  spp = xf.z;
    float  halfPx = xf.w;
    float2 pixel = (pos[iid] - origin) / spp;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 cpix = pixel + corner * halfPx;
    float2 ndc = (cpix / float(res)) * 2.0 - 1.0;
    SplatVOut o;
    // Flip Y so framebuffer rows match the pixel rows the sample pass reads.
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.texcoord = (corner + 1.0) * 0.5;
    return o;
}

fragment float4 splat_fragment(
    SplatVOut in                    [[stage_in]],
    texture2d<float, access::sample> kernelTex [[texture(0)]])
{
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return kernelTex.sample(s, in.texcoord);
}

// Sample the field at every point → repulsive force + partial Z.
kernel void tsne_field_sample(
    device const float2* pos        [[buffer(0)]],
    device float2*       repForce   [[buffer(1)]],
    device atomic_float* zSum        [[buffer(2)]],
    constant float4&     xf          [[buffer(3)]],
    constant uint&       res         [[buffer(4)]],
    constant uint&       n           [[buffer(5)]],
    texture2d<float, access::sample> field [[texture(0)]],
    threadgroup float*   scratch     [[threadgroup(0)]],
    uint gid                          [[thread_position_in_grid]],
    uint lid                          [[thread_position_in_threadgroup]],
    uint tgSize                       [[threads_per_threadgroup]])
{
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    bool active = gid < n;
    float zi = 0.0;
    if (active) {
        float2 origin = xf.xy;
        float  spp = xf.z;
        float2 pixel = (pos[gid] - origin) / spp;
        float2 uv = pixel / float(res);
        float4 f = field.sample(s, uv);
        repForce[gid] = float2(f.g, f.b);
        zi = f.r - 1.0; // remove self contribution t(0)=1
    }
    scratch[lid] = zi;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint st = tgSize / 2; st > 0; st >>= 1) {
        if (lid < st) scratch[lid] += scratch[lid + st];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) atomic_fetch_add_explicit(zSum, scratch[0], memory_order_relaxed);
}

// ===========================================================================
// Out-of-sample transform.
//
// New points are optimized against a frozen reference embedding: forces are
// computed between each new point and the reference points only, never between
// two new points. Every new point is therefore independent, and each carries its
// own normalizer Zᵢ = Σ_{j∈ref} q̃ᵢⱼ instead of one global Z, so a point lands in
// the same place whether it is transformed alone or in a batch.
// ===========================================================================

// Exact repulsion of each new point against every reference point.
//   repForce[i] = Σ_{j∈ref} q̃ᵢⱼ² (yᵢ - yⱼ),   zOut[i] = Σ_{j∈ref} q̃ᵢⱼ
kernel void tsne_transform_repulsive(
    device const float2* qpos      [[buffer(0)]],  // m new points
    device const float2* rpos      [[buffer(1)]],  // n reference points
    device float2*       repForce  [[buffer(2)]],  // m
    device float*        zOut      [[buffer(3)]],  // m
    constant uint2&      counts    [[buffer(4)]],  // (m, n)
    threadgroup float2*  tile      [[threadgroup(0)]],
    uint gid                        [[thread_position_in_grid]],
    uint lid                        [[thread_position_in_threadgroup]],
    uint tgSize                     [[threads_per_threadgroup]])
{
    uint m = counts.x, n = counts.y;
    bool active = gid < m;
    float2 yi = active ? qpos[gid] : float2(0.0);
    float2 rep = float2(0.0);
    float  z = 0.0;

    // All threads must reach the barriers, so inactive lanes ride along.
    for (uint base = 0; base < n; base += tgSize) {
        uint tcount = min(tgSize, n - base);
        if (lid < tcount) tile[lid] = rpos[base + lid];
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint c = 0; c < tcount; c++) {
            float2 diff = yi - tile[c];
            float q = 1.0 / (1.0 + dot(diff, diff));
            z += q;
            rep += (q * q) * diff;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (active) { repForce[gid] = rep; zOut[gid] = z; }
}

// Field-sampled repulsion: identical to `tsne_field_sample` but the field holds
// only the (fixed) reference points, so there is no self contribution to remove
// and Z is kept per new point rather than reduced into a global sum.
kernel void tsne_transform_field_sample(
    device const float2* qpos      [[buffer(0)]],
    device float2*       repForce  [[buffer(1)]],
    device float*        zOut      [[buffer(2)]],
    constant float4&     xf        [[buffer(3)]],
    constant uint&       res       [[buffer(4)]],
    constant uint&       m         [[buffer(5)]],
    texture2d<float, access::sample> field [[texture(0)]],
    uint gid                        [[thread_position_in_grid]])
{
    if (gid >= m) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 origin = xf.xy;
    float  spp = xf.z;
    float2 uv = ((qpos[gid] - origin) / spp) / float(res);
    float4 f = field.sample(s, uv);
    repForce[gid] = float2(f.g, f.b);
    zOut[gid] = f.r;
}

// Attraction of each new point to its k reference neighbors. The affinity rows
// are dense and equal-length (k entries per new point), so no row offsets are
// needed.
kernel void tsne_transform_attractive(
    device const float2* qpos      [[buffer(0)]],
    device const float2* rpos      [[buffer(1)]],
    device const float*  pVal      [[buffer(2)]],  // m * k, rows sum to 1
    device const uint*   colIdx    [[buffer(3)]],  // m * k, reference indices
    device float2*       attrForce [[buffer(4)]],
    constant uint2&      mk        [[buffer(5)]],  // (m, k)
    uint gid                        [[thread_position_in_grid]])
{
    uint m = mk.x, k = mk.y;
    if (gid >= m) return;
    float2 yi = qpos[gid];
    uint base = gid * k;
    float2 f = float2(0.0);
    for (uint t = 0; t < k; t++) {
        float2 d = yi - rpos[colIdx[base + t]];
        f += (pVal[base + t] / (1.0 + dot(d, d))) * d;
    }
    attrForce[gid] = f;
}

struct TransformApplyParams {
    uint  m;
    float learningRate;
    float momentum;
    float exaggeration;
    float minGain;
    float maxGradNorm;   // <= 0 disables clipping
};

// Gradient step for the new points. Same adaptive-gains + momentum scheme as the
// fit path, plus gradient-norm clipping: a new point that lands in a repulsive
// hot spot can otherwise take a single huge step and be flung out of the map.
kernel void tsne_transform_apply(
    device float2*       pos       [[buffer(0)]],
    device float2*       vel       [[buffer(1)]],
    device float2*       gains     [[buffer(2)]],
    device const float2* attrForce [[buffer(3)]],
    device const float2* repForce  [[buffer(4)]],
    device const float*  zPer      [[buffer(5)]],
    constant TransformApplyParams& p [[buffer(6)]],
    uint gid                        [[thread_position_in_grid]])
{
    uint i = gid;
    if (i >= p.m) return;
    float Z = max(zPer[i], 1e-12);
    float2 grad = 4.0 * (p.exaggeration * attrForce[i] - repForce[i] / Z);

    if (p.maxGradNorm > 0.0) {
        float nrm = length(grad);
        if (nrm > p.maxGradNorm) grad *= p.maxGradNorm / nrm;
    }

    float2 v = vel[i];
    float2 g = gains[i];
    g.x = (sign(grad.x) != sign(v.x)) ? (g.x + 0.2) : (g.x * 0.8);
    g.y = (sign(grad.y) != sign(v.y)) ? (g.y + 0.2) : (g.y * 0.8);
    g.x = max(g.x, p.minGain);
    g.y = max(g.y, p.minGain);

    v = p.momentum * v - p.learningRate * g * grad;
    vel[i] = v;
    gains[i] = g;
    pos[i] = pos[i] + v;
}

// ---------------------------------------------------------------------------
// Non-iterative projection: mode-seeking under t-SNE's own Cauchy kernel.
//
// Per query, minimize over y in R^2
//     J(y) = sum_i w_i * log(1 + ||y - Y_i||^2 / h^2),   w_i = 1/rank_i
// over its k nearest reference neighbors Y_i. That is the negative
// log-likelihood of a Cauchy mixture centered on the neighbors — and the Cauchy
// kernel is exactly t-SNE's low-dimensional affinity q ~ 1/(1+||y_i-y_j||^2),
// so the minimizer approximately maximizes the new point's own t-SNE
// likelihood against the frozen reference map.
//
// J is non-convex (that is the point: a redescending influence function lets a
// neighbor on the far side of a gap be ignored rather than averaged in), so the
// fixed point is run from every neighbor and the best objective kept. Cost is
// O(starts * iters * k) per query, entirely in registers, with no global
// repulsive field and no dependence on the number of references or queries.
// ---------------------------------------------------------------------------
#define TSNE_MAX_PROJECT_K 32

struct CauchyModeParams {
    uint  m;               // queries
    uint  k;               // neighbors per query (<= TSNE_MAX_PROJECT_K)
    uint  starts;          // fixed-point restarts, from the nearest `starts` neighbors
    uint  iterations;      // fixed-point iterations per restart
    float bandwidthScale;  // h = bandwidthScale * localScale[1-NN]
};

kernel void tsne_cauchy_mode(
    device const float2* refPos     [[buffer(0)]],  // n, the frozen map
    device const uint*   nbrIdx     [[buffer(1)]],  // m*k reference indices
    device const float*  nbrDist2   [[buffer(2)]],  // m*k squared latent distances
    device const float*  localScale [[buffer(3)]],  // n, per-reference map spacing
    device float2*       outPos     [[buffer(4)]],  // m
    constant CauchyModeParams& p    [[buffer(5)]],
    uint gid                        [[thread_position_in_grid]])
{
    if (gid >= p.m) return;
    uint k = min(p.k, (uint)TSNE_MAX_PROJECT_K);

    float2 nb[TSNE_MAX_PROJECT_K];
    float  d2[TSNE_MAX_PROJECT_K];
    float  w[TSNE_MAX_PROJECT_K];

    // The KNN kernels emit an unordered top-k, so find the nearest neighbor for
    // the bandwidth lookup before rank-ordering the rest.
    uint  base = gid * p.k;
    uint  nearest = 0;
    float nearestD2 = FLT_MAX;
    for (uint i = 0; i < k; i++) {
        float dd = nbrDist2[base + i];
        d2[i] = dd;
        nb[i] = refPos[nbrIdx[base + i]];
        if (dd < nearestD2) { nearestD2 = dd; nearest = nbrIdx[base + i]; }
    }
    // Rank order: the weights are 1/rank, so only the ordering of the latent
    // distances is used — never their magnitudes.
    for (uint i = 1; i < k; i++) {
        float key = d2[i];
        float2 keyPos = nb[i];
        int j = int(i) - 1;
        while (j >= 0 && d2[j] > key) {
            d2[j + 1] = d2[j]; nb[j + 1] = nb[j]; j--;
        }
        d2[j + 1] = key; nb[j + 1] = keyPos;
    }

    float wsumAll = 0.0;
    for (uint i = 0; i < k; i++) { w[i] = 1.0 / float(i + 1); wsumAll += w[i]; }
    for (uint i = 0; i < k; i++) w[i] /= wsumAll;

    float h = p.bandwidthScale * localScale[nearest];
    float h2 = max(h * h, 1e-20);

    uint starts = max(1u, min(p.starts, k));
    float2 best = nb[0];
    float  bestJ = FLT_MAX;
    for (uint s = 0; s < starts; s++) {
        float2 y = nb[s];
        for (uint it = 0; it < p.iterations; it++) {
            float2 acc = float2(0.0);
            float  den = 0.0;
            for (uint i = 0; i < k; i++) {
                float2 dv = y - nb[i];
                float ww = w[i] / (1.0 + dot(dv, dv) / h2);
                acc += ww * nb[i];
                den += ww;
            }
            // Every neighbor beyond the redescending tail: the current point is
            // already the local mode as far as float precision can tell.
            if (!(den > 0.0)) break;
            y = acc / den;
        }
        float J = 0.0;
        for (uint i = 0; i < k; i++) {
            float2 dv = y - nb[i];
            J += w[i] * log(1.0 + dot(dv, dv) / h2);
        }
        // NaN-safe: a failed restart never displaces the incumbent, and the
        // first restart (from the 1-NN) is always a valid fallback.
        if (J < bestJ) { bestJ = J; best = y; }
    }
    outPos[gid] = best;
}
"""
}
