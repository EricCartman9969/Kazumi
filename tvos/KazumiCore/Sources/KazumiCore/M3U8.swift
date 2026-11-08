import Foundation

/// HLS ad filtering, ported from lib/utils/m3u8_ad_filter.dart (which mimics
/// FFmpeg's hls_ad_filter): segments are grouped by EXT-X-DISCONTINUITY and
/// short groups that look like inserted ads are dropped.
public enum M3U8 {
    public static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    /// Returns the playlist with relative URIs made absolute and, for media
    /// playlists, ad groups removed. Master playlists only get URIs absolutized.
    public static func rewrite(_ text: String, baseURL: URL, filterAds: Bool) -> String {
        let lines = text.components(separatedBy: .newlines)
        func abs(_ uri: String) -> String { URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri }
        func absAttr(_ line: String) -> String {
            guard let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) else { return line }
            let inner = String(line[r]).dropFirst(5).dropLast()
            return line.replacingCharacters(in: r, with: "URI=\"\(abs(String(inner)))\"")
        }

        if isMaster(text) || !filterAds {
            return lines.map { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return l }
                if t.hasPrefix("#") { return absAttr(t) }
                return abs(t)
            }.joined(separator: "\n")
        }

        // Media playlist: collect header, segments with their group.
        struct Seg { var tags: [String]; var uri: String; var duration: Double; var group: Int }
        var header: [String] = []
        var segs: [Seg] = []
        var pending: [String] = []
        var duration = 0.0
        var group = 0
        var seenSegment = false
        var trailer: [String] = []
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t == "#EXT-X-ENDLIST" { trailer.append(t); continue }
            if t.hasPrefix("#EXT-X-DISCONTINUITY") && !t.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                if seenSegment { group += 1 }
                continue
            }
            if t.hasPrefix("#EXTINF:") {
                let v = t.dropFirst(8).split(separator: ",").first.map(String.init) ?? "0"
                duration = Double(v) ?? 0
                pending.append(t)
                continue
            }
            if t.hasPrefix("#") {
                let headerTag = !seenSegment && pending.isEmpty &&
                    (t.hasPrefix("#EXTM3U") || t.hasPrefix("#EXT-X-VERSION") || t.hasPrefix("#EXT-X-TARGETDURATION")
                     || t.hasPrefix("#EXT-X-MEDIA-SEQUENCE") || t.hasPrefix("#EXT-X-PLAYLIST-TYPE") || t.hasPrefix("#EXT-X-INDEPENDENT"))
                if headerTag { header.append(t) } else { pending.append(absAttr(t)) }
                continue
            }
            segs.append(Seg(tags: pending, uri: abs(t), duration: duration, group: group))
            pending = []
            seenSegment = true
        }

        var durations: [Int: Double] = [:]
        for s in segs { durations[s.group, default: 0] += s.duration }
        var adGroups = Set<Int>()
        if durations.count > 1, let maxD = durations.values.max() {
            let keys = durations.keys.sorted()
            for g in keys {
                let d = durations[g]!
                if d == maxD { continue }
                var ad = d < maxD * 0.3
                if (g == keys.first || g == keys.last) && d < 30 { ad = true }
                if d < 10 { ad = true }
                if ad { adGroups.insert(g) }
            }
        }
        let kept = segs.filter { !adGroups.contains($0.group) }
        let target = Int((kept.map(\.duration).max() ?? 10).rounded(.up))

        var out: [String] = []
        for h in header {
            out.append(h.hasPrefix("#EXT-X-TARGETDURATION") ? "#EXT-X-TARGETDURATION:\(target)" : h)
        }
        if !out.contains(where: { $0.hasPrefix("#EXTM3U") }) { out.insert("#EXTM3U", at: 0) }
        var lastGroup: Int?
        for s in kept {
            if let lg = lastGroup, lg != s.group { out.append("#EXT-X-DISCONTINUITY") }
            lastGroup = s.group
            out.append(contentsOf: s.tags)
            out.append(s.uri)
        }
        out.append(contentsOf: trailer)
        return out.joined(separator: "\n") + "\n"
    }

    /// Number of segments the filter would drop (for diagnostics/tests).
    public static func removedSegmentCount(_ text: String, baseURL: URL) -> Int {
        let before = text.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXTINF") }.count
        let after = rewrite(text, baseURL: baseURL, filterAds: true).components(separatedBy: .newlines).filter { $0.hasPrefix("#EXTINF") }.count
        return before - after
    }
}
