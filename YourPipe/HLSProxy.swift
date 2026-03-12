import Foundation
import AVFoundation

final class HLSProxy: NSObject, AVAssetResourceLoaderDelegate {
    let originalURL: URL
    let headers: [String: String]
    let playerId: String?
    let decoder: YouTubePlaybackService
    let queue = DispatchQueue(label: "HLSProxy.queue")
    let proxiedURL: URL

    init(originalURL: URL, headers: [String: String], playerId: String?, decoder: YouTubePlaybackService) {
        self.originalURL = originalURL
        self.headers = headers
        self.playerId = playerId
        self.decoder = decoder
        let encoded = originalURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        self.proxiedURL = URL(string: "ytproxy://manifest.m3u8?url=\(encoded)")!
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let original = originalURL(from: requestURL) else {
            return false
        }

        Task {
            await handleLoading(loadingRequest, originalURL: original)
        }
        return true
    }

    private func handleLoading(_ loadingRequest: AVAssetResourceLoadingRequest, originalURL: URL) async {
        do {
            var request = URLRequest(url: originalURL)
            headers.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                loadingRequest.finishLoading(with: NSError(domain: "HLSProxy", code: -1))
                return
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let isPlaylist = contentType.contains("mpegurl")
                || originalURL.pathExtension.lowercased() == "m3u8"
                || originalURL.absoluteString.lowercased().contains(".m3u8")

            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                let rewritten = await rewritePlaylist(text, baseURL: originalURL)
                let outputData = rewritten.data(using: .utf8) ?? data
                loadingRequest.contentInformationRequest?.contentType = "application/vnd.apple.mpegurl"
                loadingRequest.contentInformationRequest?.contentLength = Int64(outputData.count)
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
                respond(loadingRequest.dataRequest, with: outputData)
                loadingRequest.finishLoading()
                return
            }

            loadingRequest.contentInformationRequest?.contentType = contentType
            loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
            respond(loadingRequest.dataRequest, with: data)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func rewritePlaylist(_ text: String, baseURL: URL) async -> String {
        let lines = text.components(separatedBy: .newlines)
        var output: [String] = []
        output.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append(line)
                continue
            }

            if trimmed.hasPrefix("#") {
                if line.contains("URI=\"") {
                    let rewritten = await rewriteURIAttributes(in: line, baseURL: baseURL)
                    output.append(rewritten)
                } else {
                    output.append(line)
                }
                continue
            }

            if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                let decoded = await decoder.decodeThrottlingURL(resolved, playerId: playerId)
                output.append(proxyURL(for: decoded).absoluteString)
            } else {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private func rewriteURIAttributes(in line: String, baseURL: URL) async -> String {
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return line
        }
        let range = NSRange(line.startIndex..., in: line)
        var result = line
        let matches = regex.matches(in: line, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let uriRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let uriString = String(result[uriRange])
            if let resolved = URL(string: uriString, relativeTo: baseURL)?.absoluteURL {
                let decoded = await decoder.decodeThrottlingURL(resolved, playerId: playerId)
                let replacement = proxyURL(for: decoded).absoluteString
                result.replaceSubrange(uriRange, with: replacement)
            }
        }
        return result
    }

    private func isPlaylistURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains(".m3u8") || lower.contains("playlist")
    }

    private func proxyURL(for url: URL) -> URL {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "resource" : "resource.\(ext)"
        return URL(string: "ytproxy://\(suffix)?url=\(encoded)")!
    }

    private func originalURL(from proxyURL: URL) -> URL? {
        guard let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let encoded = queryItems.first(where: { $0.name == "url" })?.value,
              let decoded = encoded.removingPercentEncoding,
              let url = URL(string: decoded) else {
            return nil
        }
        return url
    }

    private func respond(_ dataRequest: AVAssetResourceLoadingDataRequest?, with data: Data) {
        guard let dataRequest else { return }
        let requestedOffset = Int(dataRequest.requestedOffset)
        let requestedLength = dataRequest.requestedLength
        let start = max(0, min(requestedOffset, data.count))
        let end: Int
        if requestedLength > 0 {
            end = min(start + requestedLength, data.count)
        } else {
            end = data.count
        }
        if start < end {
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
    }
}
