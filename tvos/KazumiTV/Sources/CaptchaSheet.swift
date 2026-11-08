import SwiftUI
import UIKit
import KazumiCore

/// Solves a rule's anti-crawler check through the companion resolver and
/// stores the resulting cookies for that rule.
struct CaptchaSheet: View {
    @EnvironmentObject var model: AppModel
    let plugin: Plugin
    let keyword: String
    let onVerified: () -> Void

    @State private var status = "正在通过伴随解析器打开验证页…"
    @State private var session: String?
    @State private var image: UIImage?
    @State private var answer = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 40) {
            Text("\(plugin.name) 人机验证").font(.title2)
            if let image {
                Image(uiImage: image)
                    .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 600, maxHeight: 220)
                    .background(Color.white)
                TextField("输入图中的字符", text: $answer)
                    .frame(maxWidth: 600)
                    .autocorrectionDisabled()
                    .onSubmit { submit() }
                Button(busy ? "提交中…" : "提交") { submit() }
                    .disabled(busy || answer.isEmpty)
            }
            if busy && image == nil { ProgressView() }
            Text(status).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(80)
        .task { await start() }
    }

    private func start() async {
        guard let companion = model.companion else {
            status = "这条规则需要人机验证，而验证要在伴随解析器上完成。请先在 设置 > 伴随解析器 中配置。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            handle(try await companion.startCaptcha(plugin: plugin, keyword: keyword))
        } catch {
            status = error.localizedDescription
        }
    }

    private func submit() {
        guard let session, let companion = model.companion, !answer.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                handle(try await companion.submitCaptcha(session: session, answer: answer))
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func handle(_ step: CompanionVideoResolver.CaptchaStep) {
        switch step {
        case .done(let cookie):
            model.cookies.set(cookie, for: plugin.name)
            status = "验证完成"
            onVerified()
        case .needsAnswer(let session, let data, let message):
            self.session = session
            image = UIImage(data: data)
            answer = ""
            status = message ?? "请输入图中的字符"
        }
    }
}
