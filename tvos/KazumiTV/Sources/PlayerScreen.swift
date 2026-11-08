import AVFoundation
import AVKit
import Combine
import SwiftUI
import KazumiCore

@MainActor
final class PlayerController: ObservableObject {
    enum Phase: Equatable {
        case resolving(String)
        case playing
        case failed(String)
    }

    @Published var phase: Phase = .resolving("正在解析视频地址…")
    @Published var request: PlayRequest
    private var statusObserver: AnyCancellable?
    let player = AVPlayer()
    private let model: AppModel
    private var resolveTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loader: HLSAdFilterLoader?
    private var lastSaved = Date.distantPast
    /// Anime4K overlay; nil when Metal is unavailable.
    let anime4k: Anime4KRenderer?
    @Published var anime4kMode: Anime4KMode

    init(request: PlayRequest, model: AppModel) {
        self.request = request
        self.model = model
        anime4kMode = model.anime4kMode
        anime4k = Anime4KRenderer(mode: model.anime4kMode)
        anime4k?.showHUD = model.anime4kHUD
        anime4k?.onDowngrade = { [weak self] mode in
            Task { @MainActor in self?.anime4kMode = mode }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var road: Road { request.roads[request.roadIndex] }
    var episodeName: String { road.episodeNames[request.episodeIndex] }
    var hasNext: Bool { request.episodeIndex + 1 < road.urls.count }

    private var started = false
    func start() {
        guard !started else { return }
        started = true
        play(episode: request.episodeIndex)
    }

    func play(episode index: Int) {
        guard road.urls.indices.contains(index) else { return }
        saveProgress(force: true)
        resolveTask?.cancel()
        player.pause()
        request.episodeIndex = index
        let pageURL = road.urls[index]
        let plugin = request.plugin
        let resolver = model.resolver
        let prefs = model.prefs
        let hint = model.resolveFailureHint
        phase = .resolving("正在解析 \(episodeName)…")
        resolveTask = Task {
            do {
                let source = try await resolver.resolve(episodeURL: pageURL, plugin: plugin)
                if Task.isCancelled { return }
                prefs.recordResolve(pluginName: plugin.name, success: true)
                load(source, pageURL: pageURL)
                rememberSource()
                prefetchNext()
            } catch {
                if Task.isCancelled { return }
                prefs.recordResolve(pluginName: plugin.name, success: false)
                var msg = error.localizedDescription
                if let hint, let ke = error as? KazumiError, case .videoSourceNotFound = ke { msg += "\n\n" + hint }
                phase = .failed(msg)
            }
        }
    }

    /// Changes the Anime4K level for this playback only; Settings holds the default.
    func setAnime4K(_ mode: Anime4KMode) {
        anime4kMode = mode
        anime4k?.setMode(mode)
    }

    func next() { if hasNext { play(episode: request.episodeIndex + 1) } }

    func retry() {
        let url = road.urls[request.episodeIndex]
        let resolver = model.resolver
        Task {
            await resolver.invalidate(url)
            play(episode: request.episodeIndex)
        }
    }

    /// Resolve the next episode while this one plays so switching is instant.
    private func prefetchNext() {
        guard hasNext else { return }
        let url = road.urls[request.episodeIndex + 1]
        let plugin = request.plugin
        let resolver = model.resolver
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await resolver.prefetch(episodeURL: url, plugin: plugin)
        }
    }

    private func rememberSource() {
        model.prefs.setPreferredSource(PreferredSource(pluginName: request.plugin.name, sourceURL: request.sourceURL,
                                                       itemName: request.subject.displayName), subjectID: request.subject.id)
    }

    private func tick() { saveProgress() }

    private func load(_ source: VideoSource, pageURL: String) {
        guard let url = URL(string: source.url) ?? URL(string: source.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
            phase = .failed("视频地址无效：\(source.url)")
            return
        }
        let useFilter = (model.globalAdFilter || request.plugin.adBlocker) && url.absoluteString.lowercased().contains(".m3u8")
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        let asset: AVURLAsset
        if useFilter {
            let loader = HLSAdFilterLoader(headers: source.headers)
            self.loader = loader
            asset = AVURLAsset(url: HLSAdFilterLoader.wrap(url), options: options)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        } else {
            loader = nil
            asset = AVURLAsset(url: url, options: options)
        }
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata()
        statusObserver = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self, status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "未知错误"
            let resolver = self.model.resolver
            Task { await resolver.invalidate(pageURL) }
            self.phase = .failed("播放器无法播放这个地址：\(reason)\n\(source.url)")
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.saveProgress(force: true)
                if self.model.autoNext { self.next() }
            }
        }
        anime4k?.attach(item)
        player.replaceCurrentItem(with: item)
        let resume = model.history.position(for: pageURL)
        if resume > 10 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        player.play()
        phase = .playing
    }

    private func metadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [item(.commonIdentifierTitle, request.subject.displayName),
                item(.iTunesMetadataTrackSubTitle, "\(episodeName) · \(request.plugin.name)")]
    }

    func saveProgress(force: Bool = false) {
        guard phase == .playing, let item = player.currentItem else { return }
        if !force && Date().timeIntervalSince(lastSaved) < 9 { return }
        let pos = player.currentTime().seconds
        let dur = item.duration.seconds
        guard pos.isFinite, pos > 0 else { return }
        lastSaved = Date()
        // Near the end counts as finished: resume the next time from the start.
        let finished = dur.isFinite && dur > 0 && pos > dur - 20
        model.record(HistoryEntry(subject: request.subject, pluginName: request.plugin.name, sourceURL: request.sourceURL,
                                  roadIndex: request.roadIndex, episodeIndex: request.episodeIndex, episodeName: episodeName,
                                  episodeURL: road.urls[request.episodeIndex], position: finished ? 0 : pos,
                                  duration: dur.isFinite ? dur : 0))
    }

    func stop() {
        saveProgress(force: true)
        resolveTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver = nil
        anime4k?.shutdown()
    }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PlayerController

    init(request: PlayRequest, model: AppModel) {
        _controller = StateObject(wrappedValue: PlayerController(request: request, model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContent(controller: controller, dismiss: { dismiss() })
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

private struct PlayerContent: View {
    @ObservedObject var controller: PlayerController
    let dismiss: () -> Void

    var body: some View {
        switch controller.phase {
        case .playing:
            AVPlayerView(controller: controller)
                .ignoresSafeArea()
        case .resolving(let message):
            VStack(spacing: 30) {
                ProgressView()
                Text(message)
                Text("\(controller.request.subject.displayName) · \(controller.request.plugin.name)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("取消", action: dismiss)
            }
            .onExitCommand(perform: dismiss)
        case .failed(let message):
            VStack(spacing: 30) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
                Text("播放失败").font(.title3)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 120)
                HStack(spacing: 40) {
                    Button("重试") { controller.retry() }
                    if controller.hasNext { Button("下一集") { controller.next() } }
                    Button("返回", action: dismiss)
                }
            }
            .onExitCommand(perform: dismiss)
        }
    }
}

/// AVPlayerViewController with Kazumi actions in the transport bar.
private struct AVPlayerView: UIViewControllerRepresentable {
    @ObservedObject var controller: PlayerController

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = controller.player
        vc.loadViewIfNeeded()
        if let overlay = vc.contentOverlayView { controller.anime4k?.install(in: overlay) }
        update(vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== controller.player { vc.player = controller.player }
        update(vc)
    }

    private func update(_ vc: AVPlayerViewController) {
        var items: [UIMenuElement] = []
        let c = controller
        if c.hasNext {
            items.append(UIAction(title: "下一集", image: UIImage(systemName: "forward.end.fill")) { _ in
                Task { @MainActor in c.next() }
            })
        }
        items.append(UIAction(title: "跳过 90 秒", image: UIImage(systemName: "goforward.90")) { _ in
            Task { @MainActor in
                let t = c.player.currentTime().seconds + 90
                c.player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            }
        })
        let road = c.road
        let episodes = road.urls.indices.map { i in
            UIAction(title: road.episodeNames[i], state: i == c.request.episodeIndex ? .on : .off) { _ in
                Task { @MainActor in c.play(episode: i) }
            }
        }
        items.append(UIMenu(title: "选集", image: UIImage(systemName: "list.number"), children: episodes))
        if c.anime4k != nil {
            let modes = Anime4KMode.allCases.map { mode in
                UIAction(title: mode.title, subtitle: mode.detail, state: mode == c.anime4kMode ? .on : .off) { _ in
                    Task { @MainActor in c.setAnime4K(mode) }
                }
            }
            items.append(UIMenu(title: "超分", image: UIImage(systemName: "sparkles.tv"), children: modes))
        }
        vc.transportBarCustomMenuItems = items

    }
}
