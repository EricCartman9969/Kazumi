import Foundation
import Metal

/// Quality levels offered in Settings. Each maps to a chain of Anime4K shaders.
enum Anime4KMode: String, CaseIterable, Identifiable {
    case off, light, standard, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关"
        case .light: return "轻量"
        case .standard: return "标准"
        case .high: return "高质量"
        }
    }

    var detail: String {
        switch self {
        case .off: return "使用系统播放器原生画面"
        case .light: return "Upscale S，GPU 占用最低"
        case .standard: return "Restore M + Upscale M"
        case .high: return "Restore VL + Upscale VL，GPU 占用很高"
        }
    }

    /// One step lower, used when frames take too long on the GPU.
    var lower: Anime4KMode {
        switch self {
        case .high: return .standard
        case .standard: return .light
        case .light, .off: return .off
        }
    }

    /// Shader chain. `upscale` is true when the screen is more than 1.2x the
    /// video, which is when Anime4K's mpv presets apply the x2 upscaler.
    func shaders(upscale: Bool) -> [String] {
        switch self {
        case .off: return []
        case .light: return upscale ? ["upscale_s"] : ["restore_s"]
        case .standard: return upscale ? ["restore_m", "upscale_m"] : ["restore_m"]
        case .high: return upscale ? ["restore_vl", "upscale_vl"] : ["restore_vl"]
        }
    }
}

enum Anime4KError: Error {
    case missingKernel(String)
    case missingTexture(String)
    case encoder
}

/// Runs the generated Anime4K kernels on a Metal texture. Intermediate
/// textures are pooled per shader and size, so steady-state playback
/// allocates nothing.
final class Anime4KProcessor {
    let device: MTLDevice
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var pool: [String: MTLTexture] = [:]
    private let lock = NSLock()
    private let storageMode: MTLStorageMode

    /// `storageMode` is `.private` for playback; the CI check uses `.shared`
    /// so it can read results back.
    init(device: MTLDevice, library: MTLLibrary, storageMode: MTLStorageMode = .private) {
        self.device = device
        self.library = library
        self.storageMode = storageMode
    }

    /// Builds every pipeline the chain needs. Call off the main thread: the
    /// VL kernels are large and take a moment to compile.
    func prepare(_ shaders: [String]) throws {
        for sid in shaders {
            for pass in Anime4KPasses.shaders[sid] ?? [] { _ = try pipeline(pass.kernel) }
        }
    }

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let fn = library.makeFunction(name: name) else { throw Anime4KError.missingKernel(name) }
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[name] = p
        return p
    }

    private func texture(_ key: String, width: Int, height: Int) -> MTLTexture? {
        let full = "\(key)@\(width)x\(height)"
        if let t = pool[full] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = storageMode
        let t = device.makeTexture(descriptor: d)
        pool[full] = t
        return t
    }

    /// Drops pooled textures, for example when the video size changes.
    func purge() { pool.removeAll() }

    /// Output size of a chain for a given input size.
    static func outputSize(shaders: [String], width: Int, height: Int) -> (Int, Int) {
        shaders.contains { $0.hasPrefix("upscale") } ? (width * 2, height * 2) : (width, height)
    }

    /// Encodes the chain and returns the texture holding the result.
    func encode(_ shaders: [String], input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        var main = input
        for sid in shaders {
            guard let passes = Anime4KPasses.shaders[sid] else { throw Anime4KError.missingKernel(sid) }
            guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw Anime4KError.encoder }
            var textures: [String: MTLTexture] = ["MAIN": main]
            for pass in passes {
                guard let ref = textures[pass.sizeOf] else { throw Anime4KError.missingTexture(pass.sizeOf) }
                let w = ref.width * pass.scale, h = ref.height * pass.scale
                guard let out = texture("\(sid).\(pass.save)", width: w, height: h) else { throw Anime4KError.missingTexture(pass.save) }
                let ps = try pipeline(pass.kernel)
                enc.setComputePipelineState(ps)
                for (i, name) in pass.binds.enumerated() {
                    guard let t = textures[name] else { throw Anime4KError.missingTexture(name) }
                    enc.setTexture(t, index: i)
                }
                enc.setTexture(out, index: pass.binds.count)
                let tw = ps.threadExecutionWidth
                let th = max(1, ps.maxTotalThreadsPerThreadgroup / tw)
                enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 16), depth: 1))
                textures[pass.save] = out
            }
            enc.endEncoding()
            guard let next = textures["MAIN"] else { throw Anime4KError.missingTexture("MAIN") }
            main = next
        }
        return main
    }
}
