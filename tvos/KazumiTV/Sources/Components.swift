import SwiftUI
import KazumiCore

struct PosterCard: View {
    let subject: BangumiSubject
    var subtitle: String? = nil
    var autoResume = false

    var body: some View {
        NavigationLink(value: SubjectRoute(subject: subject, autoResume: autoResume)) {
            VStack(alignment: .leading, spacing: 0) {
                CoverImage(url: subject.image)
                    .frame(width: 260, height: 370)
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.displayName)
                        .font(.callout).fontWeight(.semibold)
                        .lineLimit(1)
                    Text(subtitle ?? (subject.score > 0 ? String(format: "★ %.1f", subject.score) : " "))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(width: 260, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }
}

struct CoverImage: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            case .failure: placeholder
            default: placeholder.overlay(ProgressView())
            }
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color.gray.opacity(0.2))
            .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
    }
}

struct SubjectGrid: View {
    let subjects: [BangumiSubject]
    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 280), spacing: 48)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
            ForEach(subjects) { PosterCard(subject: $0) }
        }
        .padding(.horizontal, 20)
    }
}

/// Loading / error / content wrapper used by the list screens.
struct LoadState<Value> {
    var value: Value?
    var error: String?
    var loading = false
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("重试", action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
}

/// Horizontal "继续观看" row; selecting a show resumes it directly.
struct ContinueWatchingRow: View {
    let entries: [HistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("继续观看").font(.title3).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 48) {
                    ForEach(entries) { entry in
                        PosterCard(subject: entry.subject, subtitle: "\(entry.episodeName) · \(entry.pluginName)", autoResume: true)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 30)
            }
        }
    }
}
