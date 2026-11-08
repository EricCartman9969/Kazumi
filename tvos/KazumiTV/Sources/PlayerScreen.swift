import AVFoundation
import AVKit
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
    let player = AVPlayer()
    private let model: AppModel
    private var resolveTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loader: HLSAdFilterLoader?
    private var lastSaved = Date.distantPast

    init(request: PlayRequest, model: AppModel) {
        self.request = request
        self.model = model
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveProgress() }
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
        phase = .resolving("正在解析 \(episodeName)…")
        resolveTask = Task {
            do {
                let source = try await resolver.resolve(episodeURL: pageURL, plugin: plugin)
                if Task.isCancelled { return }
                load(source, pageURL: pageURL)
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func next() { if hasNext { play(episode: request.episodeIndex + 1) } }

    func retry() { play(episode: request.episodeIndex) }

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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.saveProgress(force: true)
                if self.model.autoNext { self.next() }
            }
        }
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
        vc.transportBarCustomMenuItems = items
    }
}
