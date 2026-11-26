import AVFoundation
import Foundation
import UniformTypeIdentifiers

// AVPlayer handles media segments over HTTPS. The loader authenticates and rewrites only playlists.
final class PlexVideoManifest: NSObject, AVAssetResourceLoaderDelegate {
    static let compatibilityProfile = "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
    static let prefix = "/video/:/transcode/universal/"
    private static let scheme = "iplex-hls"
    private let queue = DispatchQueue(label: "net.bentley734.musicroom.video-manifest")
    private var requests: [ObjectIdentifier: PlexRequestOperation] = [:]
    private var origin: URL?

    func asset(_ url: URL) -> AVURLAsset {
        origin = url
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = Self.scheme
        let asset = AVURLAsset(url: parts.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let origin, let requested = request.request.url,
              var parts = URLComponents(url: requested, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme else { return false }
        parts.scheme = origin.scheme
        guard let target = parts.url, target.host == origin.host, target.port == origin.port,
              target.path.hasPrefix(Self.prefix), target.pathExtension == "m3u8" else { return false }
        let id = ObjectIdentifier(request)
        let operation = PlexRequestOperation()
        requests[id] = operation
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                var upstream = URLRequest(url: target)
                upstream.setValue("application/vnd.apple.mpegurl", forHTTPHeaderField: "Accept")
                let data = try operation.fetch(upstream, limit: 4 * 1024 * 1024, timeout: 30)
                return try Self.rewrite(data, target: target, origin: origin)
            }
            self.queue.async {
                guard self.requests.removeValue(forKey: id) != nil else { return }
                switch result {
                case .success(let data):
                    request.contentInformationRequest?.contentType = UTType(filenameExtension: "m3u8")?.identifier
                    request.contentInformationRequest?.contentLength = Int64(data.count)
                    request.contentInformationRequest?.isByteRangeAccessSupported = false
                    request.dataRequest?.respond(with: data)
                    request.finishLoading()
                case .failure(let error):
                    request.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    static func rewrite(_ data: Data, target: URL, origin: URL) throws -> Data {
        let error = PlexServiceError("Plex returned an invalid video playlist.")
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U"),
              let credentials = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.queryItems?
                .filter({ ["X-Plex-Token", "X-Plex-Client-Identifier"].contains($0.name) }) else { throw error }
        func link(_ value: String) throws -> String {
            guard let resolved = URL(string: value, relativeTo: target)?.absoluteURL,
                  resolved.scheme == origin.scheme, resolved.host == origin.host, resolved.port == origin.port,
                  resolved.user == nil, resolved.password == nil, resolved.fragment == nil,
                  resolved.path.hasPrefix(prefix), !resolved.path.contains(".."),
                  var fields = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { throw error }
            let query = fields.queryItems ?? []
            fields.queryItems = query.filter { item in !credentials.contains(where: { $0.name == item.name }) } + credentials
            if resolved.pathExtension == "m3u8" { fields.scheme = scheme }
            guard let url = fields.url else { throw error }
            return url.absoluteString
        }
        let attribute = try NSRegularExpression(pattern: #"(?:^|[:,])(?:URI|SERVER-URI|X-ASSET-URI|X-ASSET-LIST)="([^"]+)""#)
        let lines = try text.components(separatedBy: CharacterSet.newlines).map { line in
            guard !line.isEmpty else { return line }
            guard line.hasPrefix("#") else { return try link(line) }
            var result = line
            let captures = attribute.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in captures.reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { throw error }
                result.replaceSubrange(range, with: try link(String(result[range])))
            }
            return result
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
