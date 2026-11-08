import AVFoundation
import CoreVideo
import MetalKit
import QuartzCore
import UIKit

/// Pulls decoded frames from the player item, runs Anime4K on them and draws
/// the result into an MTKView that sits in AVPlayerViewController's
/// contentOverlayView, under the system transport controls. The system
/// player keeps rendering underneath, so hiding the view falls back to the
/// native picture instantly.
final class Anime4KRenderer: NSObject, MTKViewDelegate {
    let view: MTKView
    private let queue: MTLCommandQueue
    private let processor: Anime4KProcessor
    private let presentPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private let hud = UILabel()
    private var noticeUntil = Date.distantPast
    private var notice: String?

    private(set) var mode: Anime4KMode = .off
    var showHUD = false { didSet { refreshHUD() } }
    /// Called on the main thread when the renderer steps down a level.
    var onDowngrade: ((Anime4KMode) -> Void)?

    private var prepared: Set<String> = []
    private var preparing: Set<String> = []
    private var inflight = 0
    private var hasFrame = false
    private var videoSize = CGSize.zero
    private var lastShaders: [String] = []

    // Timing, all on the main thread.
    private var lastItemTime = -1.0
    private var frameInterval = 1.0 / 24.0
    private var gpuSamples: [Double] = []
    private var gpuAverage = 0.0
    private var slowWindows = 0

    init?(mode: Anime4KMode) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "anime4k_present_vertex"),
              let ffn = library.makeFunction(name: "anime4k_present_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.queue = queue
        self.presentPipeline = pipeline
        self.processor = Anime4KProcessor(device: device, library: library)
        view = MTKView(frame: .zero, device: device)
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.isUserInteractionEnabled = false
        view.delegate = self
        hud.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hud.numberOfLines = 0
        hud.layer.cornerRadius = 10
        hud.clipsToBounds = true
        hud.isHidden = true
        setMode(mode)
    }

    /// Puts the view (and the HUD) into the player's overlay.
    func install(in container: UIView) {
        guard view.superview !== container else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -80),
        ])
        updateVisibility()
    }

    func setMode(_ newMode: Anime4KMode) {
        mode = newMode
        slowWindows = 0
        gpuSamples.removeAll()
        hasFrame = false
        if newMode == .off {
            detachOutput()
            processor.purge()
        } else if let item, output == nil {
            attachOutput(to: item)
        }
        view.isPaused = newMode == .off
        updateVisibility()
        refreshHUD()
    }

    /// Call for every new AVPlayerItem.
    func attach(_ newItem: AVPlayerItem) {
        detachOutput()
        item = newItem
        hasFrame = false
        lastItemTime = -1
        updateVisibility()
        if mode != .off { attachOutput(to: newItem) }
    }

    private func attachOutput(to item: AVPlayerItem) {
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.suppressesPlayerRendering = false
        item.add(out)
        output = out
    }

    private func detachOutput() {
        if let output, let item, item.outputs.contains(output) { item.remove(output) }
        output = nil
    }

    func shutdown() {
        view.isPaused = true
        view.delegate = nil
        detachOutput()
        processor.purge()
    }

    private func updateVisibility() {
        view.isHidden = mode == .off || !hasFrame
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard mode != .off, let output, inflight < 2, let cache = textureCache else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        trackFrameInterval(itemTime.seconds)

        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTexture, let input = CVMetalTextureGetTexture(cvTexture) else { return }
        if videoSize != CGSize(width: w, height: h) {
            videoSize = CGSize(width: w, height: h)
            processor.purge()
        }

        let drawable = view.drawableSize
        let fit = min(drawable.width / CGFloat(w), drawable.height / CGFloat(h))
        let shaders = mode.shaders(upscale: fit > 1.2)
        guard ensurePrepared(shaders) else { return }
        lastShaders = shaders

        guard let cb = queue.makeCommandBuffer() else { return }
        let result: MTLTexture
        do {
            result = try processor.encode(shaders, input: input, commandBuffer: cb)
        } catch {
            downgrade(reason: "超分出错，已关闭")
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let target = view.currentDrawable,
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vw = CGFloat(result.width), vh = CGFloat(result.height)
        let scale = min(drawable.width / vw, drawable.height / vh)
        let ow = vw * scale, oh = vh * scale
        enc.setViewport(MTLViewport(originX: Double((drawable.width - ow) / 2), originY: Double((drawable.height - oh) / 2),
                                    width: Double(ow), height: Double(oh), znear: 0, zfar: 1))
        enc.setRenderPipelineState(presentPipeline)
        enc.setFragmentTexture(result, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(target)
        inflight += 1
        cb.addCompletedHandler { [weak self] buffer in
            _ = cvTexture // keep the frame alive until the GPU is done with it
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.finished(gpuMs: ms, failed: buffer.status == .error) }
        }
        cb.commit()
    }

    private func ensurePrepared(_ shaders: [String]) -> Bool {
        let key = shaders.joined(separator: "+")
        if prepared.contains(key) { return true }
        if !preparing.contains(key) {
            preparing.insert(key)
            let processor = self.processor
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = (try? processor.prepare(shaders)) != nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.preparing.remove(key)
                    if ok { self.prepared.insert(key) } else { self.downgrade(reason: "超分着色器加载失败，已关闭") }
                }
            }
        }
        return false
    }

    private func trackFrameInterval(_ t: Double) {
        if lastItemTime >= 0 {
            let d = t - lastItemTime
            if d > 0.005 && d < 0.2 { frameInterval = frameInterval * 0.9 + d * 0.1 }
        }
        lastItemTime = t
    }

    private func finished(gpuMs: Double, failed: Bool) {
        inflight = max(0, inflight - 1)
        if failed {
            downgrade(reason: "GPU 出错，已降一档")
            return
        }
        if !hasFrame {
            hasFrame = true
            updateVisibility()
        }
        gpuSamples.append(gpuMs)
        guard gpuSamples.count >= 48 else { return }
        gpuAverage = gpuSamples.reduce(0, +) / Double(gpuSamples.count)
        gpuSamples.removeAll()
        // Leave some headroom for the system compositor and the video decoder.
        let budget = frameInterval * 1000 * 0.85
        slowWindows = gpuAverage > budget ? slowWindows + 1 : 0
        refreshHUD()
        if slowWindows >= 2 { downgrade(reason: "GPU 跟不上（平均 \(String(format: "%.1f", gpuAverage)) ms/帧），已降一档") }
    }

    private func downgrade(reason: String) {
        let next = mode.lower
        notice = reason + (next == .off ? "" : "：\(next.title)")
        noticeUntil = Date().addingTimeInterval(6)
        setMode(next)
        onDowngrade?(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { [weak self] in self?.refreshHUD() }
    }

    private func refreshHUD() {
        var lines: [String] = []
        if let notice, Date() < noticeUntil { lines.append(notice) }
        if showHUD && mode != .off {
            let ins = "\(Int(videoSize.width))×\(Int(videoSize.height))"
            let (ow, oh) = Anime4KProcessor.outputSize(shaders: lastShaders, width: Int(videoSize.width), height: Int(videoSize.height))
            lines.append("Anime4K \(mode.title) · \(lastShaders.joined(separator: " + "))")
            lines.append("\(ins) → \(ow)×\(oh)")
            lines.append(String(format: "GPU %.1f ms / 帧间隔 %.1f ms", gpuAverage, frameInterval * 1000))
        }
        hud.text = lines.isEmpty ? nil : lines.map { "  \($0)  " }.joined(separator: "\n")
        hud.isHidden = lines.isEmpty
    }
}
