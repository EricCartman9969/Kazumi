import Foundation

/// Parses a URL string leniently: hrefs scraped from pages may contain spaces
/// or non-ASCII characters that `URL(string:)` rejects on some platforms.
func lenientURL(_ string: String, relativeTo base: URL? = nil) -> URL? {
    if let u = URL(string: string, relativeTo: base) { return u }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.insert(charactersIn: "#%/:?&=+;@[]!$'()*,~")
    guard let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: encoded, relativeTo: base)
}

private func isHTTP(_ scheme: String?) -> Bool { scheme == "http" || scheme == "https" }

/// Port of `normalizeEpisodeUrl` (lib/utils/episode_url.dart): turns a raw
/// href into a stable absolute URL so the same episode always maps to the same
/// key for history and resume.
public func normalizeEpisodeURL(baseURL: String, raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    let hasValidBase = base?.scheme != nil && !(base?.host ?? "").isEmpty

    var resolved: URL?
    if let rawURL = lenientURL(trimmed), rawURL.scheme != nil, !(rawURL.host ?? "").isEmpty {
        resolved = rawURL
    } else if hasValidBase {
        resolved = lenientURL(trimmed, relativeTo: base)?.absoluteURL
    }
    guard let r = resolved, var comps = URLComponents(url: r, resolvingAgainstBaseURL: true),
          !(comps.host ?? "").isEmpty else {
        return trimmed
    }

    if hasValidBase, let base, isHTTP(base.scheme), isHTTP(comps.scheme),
       comps.scheme != base.scheme, comps.host == base.host, comps.port == base.port {
        comps.scheme = base.scheme
    }

    var path = comps.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    comps.percentEncodedPath = path
    if comps.percentEncodedQuery?.isEmpty == true { comps.percentEncodedQuery = nil }
    if comps.percentEncodedFragment?.isEmpty == true { comps.percentEncodedFragment = nil }
    return comps.string ?? trimmed
}
