import AVFoundation
import KazumiCore

/// Serves HLS playlists through AVAssetResourceLoader so ad segments can be
/// removed before AVPlayer sees them (the same discontinuity-group heuristic
/// Kazumi uses, see KazumiCore/M3U8.swift). Only playlists go through here;
/// media segments keep their real http(s) URLs and are fetched by AVPlayer.
final class HLSAdFilterLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let schemes = ["http": "kzhttp", "https": "kzhttps"]
    private let headers: [String: String]
    private let session = URLSession(configuration: .default)
    let queue = DispatchQueue(label: "kazumi.hls.loader")

    init(headers: [String: String]) {
        self.headers = headers
    }

    static func wrap(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme, let custom = schemes[scheme] else { return url }
        comps.scheme = custom
        return comps.url ?? url
    }

    static func unwrap(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = comps.scheme,
              let original = schemes.first(where: { $0.value == scheme })?.key else { return nil }
        comps.scheme = original
        return comps.url
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let real = Self.unwrap(url) else { return false }
        var req = URLRequest(url: real, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        session.dataTask(with: req) { data, response, error in
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                loadingRequest.finishLoading(with: URLError(.cannotDecodeContentData))
                return
            }
            let base = response?.url ?? real
            var output: String
            if M3U8.isMaster(text) {
                // Route variant playlists back through this loader so they get filtered too.
                output = M3U8.rewrite(text, baseURL: base, filterAds: false)
                output = output.components(separatedBy: "\n").map { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("#") {
                        if t.hasPrefix("#EXT-X-MEDIA"), let r = t.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                            let inner = String(t[r].dropFirst(5).dropLast())
                            if let u = URL(string: inner) { return t.replacingCharacters(in: r, with: "URI=\"\(Self.wrap(u).absoluteString)\"") }
                        }
                        return line
                    }
                    return URL(string: t).map { Self.wrap($0).absoluteString } ?? line
                }.joined(separator: "\n")
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                output = M3U8.rewrite(text, baseURL: base, filterAds: true)
            } else {
                loadingRequest.finishLoading(with: URLError(.cannotParseResponse))
                return
            }
            let body = Data(output.utf8)
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(body.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
        }.resume()
        return true
    }
}
