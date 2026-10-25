import Foundation
import Metal

/// Owns the Metal device, command queue, and the compute pipelines used by the
/// embedding. Shaders are compiled from embedded source at runtime, so no
/// offline Metal toolchain is required by consumers of the library.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private var renderPipelineCache: [String: MTLRenderPipelineState] = [:]
    private let cacheLock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TSNEError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw TSNEError.noMetalDevice
        }
        self.device = device
        self.queue = queue

        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            self.library = try device.makeLibrary(source: MetalShaders.source, options: options)
        } catch {
            throw TSNEError.shaderCompilationFailed(String(describing: error))
        }
    }

    /// Returns (and caches) a render pipeline with **additive blending** on a
    /// single color attachment of `pixelFormat`. Used by the field-splatting
    /// optimizer to accumulate the kernel field. Throws if the device cannot
    /// create the pipeline (e.g. if the format is not blendable).
    func renderPipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = "\(vertex)|\(fragment)|\(pixelFormat.rawValue)"
        cacheLock.lock()
        let cached = renderPipelineCache[key]
        cacheLock.unlock()
        if let cached { return cached }
        guard let vfn = library.makeFunction(name: vertex),
              let ffn = library.makeFunction(name: fragment) else {
            throw TSNEError.pipelineCreationFailed("\(vertex)/\(fragment)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let att = desc.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .one
        att.destinationAlphaBlendFactor = .one
        do {
            let ps = try device.makeRenderPipelineState(descriptor: desc)
            cacheLock.lock()
            if let cached = renderPipelineCache[key] {
                cacheLock.unlock()
                return cached
            }
            renderPipelineCache[key] = ps
            cacheLock.unlock()
            return ps
        } catch {
            throw TSNEError.pipelineCreationFailed("render \(vertex)/\(fragment): \(error)")
        }
    }

    /// Returns (and caches) the compute pipeline for a named kernel.
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        cacheLock.lock()
        let cached = pipelineCache[name]
        cacheLock.unlock()
        if let cached { return cached }
        guard let function = library.makeFunction(name: name) else {
            throw TSNEError.pipelineCreationFailed(name)
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw TSNEError.pipelineCreationFailed("\(name): \(error)")
        }
        cacheLock.lock()
        if let cached = pipelineCache[name] {
            cacheLock.unlock()
            return cached
        }
        pipelineCache[name] = pipeline
        cacheLock.unlock()
        return pipeline
    }

    /// Returns (and caches) a compute pipeline **specialized** on `uint` function
    /// constants. Specializing turns a runtime loop bound into a compile-time
    /// one, which is what lets the compiler unroll a loop and keep a small array
    /// in registers instead of spilling it to (device-backed) thread-local
    /// memory. One pipeline is built per distinct constant set and cached.
    func pipeline(_ name: String, constants: [Int: UInt32]) throws -> MTLComputePipelineState {
        let key = name + "|" + constants.keys.sorted().map { "\($0)=\(constants[$0]!)" }.joined(separator: ",")
        cacheLock.lock()
        let cached = pipelineCache[key]
        cacheLock.unlock()
        if let cached { return cached }
        let values = MTLFunctionConstantValues()
        for (index, value) in constants {
            var v = value
            values.setConstantValue(&v, type: .uint, index: index)
        }
        let function: MTLFunction
        do {
            function = try library.makeFunction(name: name, constantValues: values)
        } catch {
            throw TSNEError.pipelineCreationFailed("\(name) specialization: \(error)")
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw TSNEError.pipelineCreationFailed("\(key): \(error)")
        }
        cacheLock.lock()
        if let cached = pipelineCache[key] {
            cacheLock.unlock()
            return cached
        }
        pipelineCache[key] = pipeline
        cacheLock.unlock()
        return pipeline
    }

    // MARK: - Field-splatting resources

    /// Support radius of the Student-t splat kernel, in embedding units. Shared
    /// by the kernel texture and the embedding→field transform.
    static let kernelRadius: Float = 2.5

    /// Field resolution for `n` splatted points: next power of two ≥ 2·√N,
    /// clamped to [256, 2048]. The render-pass cost scales with the texel count,
    /// so we keep this as small as fidelity allows (the kernel window is bounded
    /// in pixels independently).
    static func fieldResolution(count n: Int) -> Int {
        let target = Int((Double(n).squareRoot() * 2).rounded())
        var r = 256
        while r < target && r < 2048 { r <<= 1 }
        return min(2048, max(256, r))
    }

    /// The embedding→field transform `{originX, originY, spacePerPixel,
    /// halfKernelPx}` for points bounded by `lo`/`hi`. Mirrors what
    /// `tsne_reduce_bounds_stage2` computes on the GPU during a fit.
    static func fieldTransform(lo: SIMD2<Float>, hi: SIMD2<Float>, resolution res: Int) -> SIMD4<Float> {
        let center = 0.5 * (lo + hi)
        let maxWindowPx: Float = 5.0
        var span = max(hi.x - lo.x, hi.y - lo.y) + 2 * kernelRadius
        span = max(span, 1e-4)
        let spp = max(span / Float(res), kernelRadius / maxWindowPx)
        return SIMD4(center.x - 0.5 * Float(res) * spp,
                     center.y - 0.5 * Float(res) * spp,
                     spp,
                     kernelRadius / spp)
    }

    /// Precomputes the 64×64 Student-t kernel texture: channels (t, t²·δx, t²·δy,
    /// 1) over the offset range δ ∈ [-2.5, 2.5]² in embedding units.
    func makeKernelTexture() throws -> MTLTexture {
        let K = 64
        let radius = MetalContext.kernelRadius
        var data = [SIMD4<Float>](repeating: .zero, count: K * K)
        for iy in 0..<K {
            for ix in 0..<K {
                let dx = ((Float(ix) + 0.5) / Float(K) - 0.5) * 2 * radius
                let dy = ((Float(iy) + 0.5) / Float(K) - 0.5) * 2 * radius
                let t = 1.0 / (1.0 + dx * dx + dy * dy)
                data[iy * K + ix] = SIMD4(t, t * t * dx, t * t * dy, 1.0)
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: K, height: K, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw TSNEError.bufferAllocationFailed
        }
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, K, K), mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: K * MemoryLayout<SIMD4<Float>>.stride)
        }
        return tex
    }

    /// Allocates the render target the kernel splats accumulate into.
    func makeFieldTexture(resolution r: Int) throws -> MTLTexture {
        // 16-bit float: blendable + filterable everywhere, half the ROP/memory
        // traffic of 32-bit. Precision is ample for the (already approximate)
        // repulsive field.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: r, height: r, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw TSNEError.bufferAllocationFailed
        }
        return tex
    }

    /// Whether this device can build the splat render pipeline (blendable
    /// RGBA16Float). Callers fall back to the exact N-body path if not.
    var supportsFieldSplatting: Bool {
        (try? renderPipeline(vertex: "splat_vertex", fragment: "splat_fragment",
                             pixelFormat: .rgba16Float)) != nil
    }

    /// Allocates a shared-storage buffer of `count` elements of type `T`,
    /// optionally copying from `source`.
    func makeBuffer<T>(_ type: T.Type, count: Int, from source: [T]? = nil) throws -> MTLBuffer {
        // Metal does not create zero-length buffers. Keep the logical element
        // count at zero for callers while allocating one unused element so
        // empty CSR arrays and other valid empty resources remain representable.
        let length = max(1, count) * MemoryLayout<T>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw TSNEError.bufferAllocationFailed
        }
        if let source, count > 0 {
            source.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: count * MemoryLayout<T>.stride)
            }
        }
        return buffer
    }
}

extension MTLBuffer {
    /// Typed view over the buffer's contents.
    func array<T>(_ type: T.Type, count: Int) -> [T] {
        let ptr = contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    func pointer<T>(_ type: T.Type) -> UnsafeMutablePointer<T> {
        contents().bindMemory(to: T.self, capacity: 1)
    }
}
