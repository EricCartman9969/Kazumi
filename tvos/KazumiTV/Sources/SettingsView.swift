import SwiftUI
import KazumiCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var resolverStatus: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("地址，例如 http://192.168.1.10:8787", text: $model.resolverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                SecureField("令牌（可选，对应 RESOLVER_TOKEN）", text: $model.resolverToken)
                Picker("解析方式", selection: $model.resolveMode) {
                    ForEach(ResolveMode.allCases) { Text($0.title).tag($0) }
                }
                DiscoveryRows(discovery: model.discovery) { url in
                    model.resolverURL = url
                    Task { await test() }
                }
                Button(testing ? "测试中…" : "测试连接") { Task { await test() } }
                    .disabled(testing || model.resolverURL.isEmpty)
                if let resolverStatus {
                    Text(resolverStatus).foregroundStyle(.secondary)
                }
            } header: {
                Text("伴随解析器")
            } footer: {
                Text("Apple TV 没有浏览器内核，部分片源的视频地址需要在 Mac、NAS 或服务器上运行伴随解析器（仓库 tvos-resolver 目录）才能获取。")
            }

            Section("播放") {
                Toggle("过滤 HLS 插播广告", isOn: $model.globalAdFilter)
                Toggle("自动播放下一集", isOn: $model.autoNext)
            }
            Section {
                Picker("Anime4K 超分辨率", selection: $model.anime4kMode) {
                    ForEach(Anime4KMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("显示超分性能信息", isOn: $model.anime4kHUD)
            } header: {
                Text("画质增强")
            } footer: {
                Text("\(model.anime4kMode.detail)。屏幕比视频大 1.2 倍以上时才放大，否则只做画质修复。GPU 跟不上时会自动降一档。播放中也可以在播放器菜单里切换。")
            }

            Section {
                NavigationLink("规则管理（\(model.plugins.count) 条）") { RulesView() }
                Toggle("通过镜像下载规则", isOn: $model.useRuleMirror)
            } header: {
                Text("规则")
            } footer: {
                Text("规则来自 Predidit/KazumiRules，与 Kazumi 应用通用。")
            }

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("基于 Kazumi（github.com/Predidit/Kazumi）的 Apple TV 客户端，GPLv3 许可。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }

    private func test() async {
        guard let companion = model.companion else { return }
        testing = true
        defer { testing = false }
        do {
            let version = try await companion.health()
            resolverStatus = "已连接，解析器版本 \(version)"
        } catch {
            resolverStatus = error.localizedDescription
        }
    }
}

struct RulesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                Button(model.isSyncingRules ? "同步中…" : "更新已安装规则") {
                    Task { await model.syncRules(installMissing: false) }
                }
                .disabled(model.isSyncingRules)
                Button("安装仓库中的全部规则") {
                    Task { await model.syncRules(installMissing: true) }
                }
                .disabled(model.isSyncingRules)
                if let msg = model.ruleSyncMessage {
                    Text(msg).foregroundStyle(.secondary)
                }
            }
            Section("已安装（点按启用或停用）") {
                ForEach(model.plugins) { plugin in
                    let enabled = !model.disabledPlugins.contains(plugin.id)
                    Button {
                        model.setPlugin(plugin.id, enabled: !enabled)
                    } label: {
                        HStack {
                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(plugin.name)
                                Text(details(plugin)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("v\(plugin.version)").foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) { model.removePlugin(plugin.id) }
                    }
                }
            }
        }
        .navigationTitle("规则管理")
    }

    private func details(_ p: Plugin) -> String {
        var parts = [p.searchMode == .api ? "接口搜索" : "XPath 搜索"]
        if p.antiCrawlerConfig.enabled { parts.append("有人机验证，可能无法使用") }
        if p.useLegacyParser { parts.append("旧版解析") }
        return parts.joined(separator: " · ")
    }
}

/// Lists resolvers found on the LAN via Bonjour.
private struct DiscoveryRows: View {
    @ObservedObject var discovery: ResolverDiscovery
    let choose: (String) -> Void

    var body: some View {
        Button(discovery.isBrowsing ? "正在查找局域网解析器…" : "自动查找局域网解析器") {
            discovery.start()
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                discovery.stop()
            }
        }
        ForEach(discovery.found) { found in
            Button {
                choose(found.url)
            } label: {
                LabeledContent(found.name, value: found.url)
            }
        }
    }
}
