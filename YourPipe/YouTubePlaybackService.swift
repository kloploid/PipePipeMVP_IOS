import Foundation

actor YouTubePlaybackService {
    static let shared = YouTubePlaybackService()

    private let session: URLSession
    private let iosKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private let iosClientVersion = "21.03.2"
    private let iosDeviceModel = "iPhone16,2"
    private let iosOSVersion = "18.7.2.22H124"
    private let iosUserAgentVersion = "18_7_2"
    private let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    private let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private let decoderBaseURL = "https://api.pipepipe.dev/decoder/decode"
    private let decoderUserAgent = "PipePipe/4.7.0"
    private var decoderCache: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct PlaybackData {
        let streamURL: URL
        let title: String?
        let channelName: String?
        let channelId: String?
        let description: String?
        let headers: [String: String]
        let playerId: String?
    }

    enum PlaybackError: LocalizedError {
        case invalidURL
        case invalidResponse
        case invalidJSON
        case httpStatus(Int, String)
        case decoderFailed
        case noPlayableStream

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Не удалось сформировать запрос плеера."
            case .invalidResponse:
                return "Сервер плеера вернул некорректный ответ."
            case .invalidJSON:
                return "Не удалось разобрать ответ плеера."
            case .httpStatus(let code, _):
                return "Ошибка загрузки видео: HTTP \(code)."
            case .decoderFailed:
                return "Не удалось декодировать параметры потока."
            case .noPlayableStream:
                return "Для этого видео не найден встроенный поток воспроизведения."
            }
        }
    }

    func resolve(videoId: String) async throws -> PlaybackData {
        return try await resolveViaInnerTube(videoId: videoId)
    }

    private func resolveViaInnerTube(videoId: String) async throws -> PlaybackData {
        var components = URLComponents(string: "https://youtubei.googleapis.com/youtubei/v1/player")!
        let t = String((0..<12).map { _ in nonceAlphabet.randomElement()! })
        components.queryItems = [
            URLQueryItem(name: "key", value: iosKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "id", value: videoId)
        ]
        guard let url = components.url else { throw PlaybackError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iosUserAgent(countryCode: "US"), forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": iosClientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": iosDeviceModel,
                    "platform": "MOBILE",
                    "osName": "iOS",
                    "osVersion": iosOSVersion,
                    "hl": "en",
                    "gl": "US",
                    "utcOffsetMinutes": 0
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "videoId": videoId,
            "cpn": String((0..<16).map { _ in nonceAlphabet.randomElement()! }),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlaybackError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }

#if DEBUG
        if let playability = root["playabilityStatus"] as? [String: Any] {
            let status = playability["status"] as? String ?? "unknown"
            let reason = playability["reason"] as? String ?? "none"
            print("[YouTubePlaybackService] InnerTube playability status=\(status) reason=\(reason)")
        }
#endif

        logStreamingDataIfNeeded(root: root, source: "InnerTube")

        let videoDetails = root["videoDetails"] as? [String: Any]
        let title = videoDetails?["title"] as? String
        let channelName = videoDetails?["author"] as? String
        let channelId = videoDetails?["channelId"] as? String
        let description = videoDetails?["shortDescription"] as? String
        let isLiveContent = videoDetails?["isLiveContent"] as? Bool ?? false
        let playerId = await resolvePlayerId(videoId: videoId, root: root)
#if DEBUG
        print("[YouTubePlaybackService] playerId=\(playerId ?? "none")")
#endif

        let formats = ((root["streamingData"] as? [String: Any])?["formats"] as? [[String: Any]]) ?? []
        let hlsURLString = (root["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String

        if !isLiveContent {
            if let directURL = await pickBestMuxedMP4URL(from: formats, playerId: playerId) {
#if DEBUG
                print("[YouTubePlaybackService] InnerTube: using muxed format url")
#endif
                return PlaybackData(
                    streamURL: directURL,
                    title: title,
                    channelName: channelName,
                    channelId: channelId,
                    description: description,
                    headers: streamHeaders(videoId: videoId, userAgent: iosUserAgent(countryCode: "US")),
                    playerId: playerId
                )
            }
            if let hlsURLString, let url = URL(string: hlsURLString) {
#if DEBUG
                print("[YouTubePlaybackService] InnerTube: using hlsManifestUrl")
#endif
                let finalURL = await decodeThrottlingIfNeeded(url: url, playerId: playerId)
                return PlaybackData(
                    streamURL: finalURL,
                    title: title,
                    channelName: channelName,
                    channelId: channelId,
                    description: description,
                    headers: streamHeaders(videoId: videoId, userAgent: iosUserAgent(countryCode: "US")),
                    playerId: playerId
                )
            }
        } else if let hlsURLString, let url = URL(string: hlsURLString) {
#if DEBUG
            print("[YouTubePlaybackService] InnerTube: using hlsManifestUrl")
#endif
            let finalURL = await decodeThrottlingIfNeeded(url: url, playerId: playerId)
            return PlaybackData(
                streamURL: finalURL,
                title: title,
                channelName: channelName,
                channelId: channelId,
                description: description,
                headers: streamHeaders(videoId: videoId, userAgent: iosUserAgent(countryCode: "US")),
                playerId: playerId
            )
        }

        throw PlaybackError.noPlayableStream
    }

    private func resolveViaWatchPage(videoId: String) async throws -> PlaybackData {
        let watchURLString = "https://www.youtube.com/watch?v=\(videoId)"
        guard let watchURL = URL(string: watchURLString) else { throw PlaybackError.invalidURL }

        var request = URLRequest(url: watchURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaybackError.invalidResponse
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw PlaybackError.invalidResponse
        }

        guard let playerJSON = extractPlayerResponseJSON(from: html),
              let jsonData = playerJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }

        logStreamingDataIfNeeded(root: root, source: "WatchPage")

        let videoDetails = root["videoDetails"] as? [String: Any]
        let title = videoDetails?["title"] as? String
        let channelName = videoDetails?["author"] as? String
        let channelId = videoDetails?["channelId"] as? String
        let description = videoDetails?["shortDescription"] as? String
        let isLiveContent = videoDetails?["isLiveContent"] as? Bool ?? false
        let playerId = await resolvePlayerId(videoId: videoId, root: root)
#if DEBUG
        print("[YouTubePlaybackService] playerId=\(playerId ?? "none")")
#endif

        let streamingData = root["streamingData"] as? [String: Any]
        let hlsURLString = streamingData?["hlsManifestUrl"] as? String
        if let formats = streamingData?["formats"] as? [[String: Any]] {
            if !isLiveContent, let directURL = await pickBestMuxedMP4URL(from: formats, playerId: playerId) {
#if DEBUG
                print("[YouTubePlaybackService] WatchPage: using muxed format url")
#endif
                return PlaybackData(
                    streamURL: directURL,
                    title: title,
                    channelName: channelName,
                    channelId: channelId,
                    description: description,
                    headers: streamHeaders(videoId: videoId, userAgent: webUserAgent),
                    playerId: playerId
                )
            }
        }
        if let hlsURLString, let url = URL(string: hlsURLString) {
#if DEBUG
            print("[YouTubePlaybackService] WatchPage: using hlsManifestUrl")
#endif
            let finalURL = await decodeThrottlingIfNeeded(url: url, playerId: playerId)
            return PlaybackData(
                streamURL: finalURL,
                title: title,
                channelName: channelName,
                channelId: channelId,
                description: description,
                headers: streamHeaders(videoId: videoId, userAgent: webUserAgent),
                playerId: playerId
            )
        }

        throw PlaybackError.noPlayableStream
    }

    private func pickBestMuxedMP4URL(from formats: [[String: Any]], playerId: String?) async -> URL? {
        let muxed = formats.filter { isMuxedMP4($0) }

        // Prefer itag=18 (H.264 + AAC, muxed MP4) when available.
        if let itag18 = muxed.first(where: { ($0["itag"] as? Int) == 18 }),
           let url = await resolvePlayableURL(from: itag18, playerId: playerId) {
            return url
        }

        let sorted = muxed.sorted { lhs, rhs in
            let lw = lhs["width"] as? Int ?? 0
            let rw = rhs["width"] as? Int ?? 0
            if lw == rw {
                let lbit = lhs["bitrate"] as? Int ?? 0
                let rbit = rhs["bitrate"] as? Int ?? 0
                return lbit > rbit
            }
            return lw > rw
        }

        for item in sorted {
            if let url = await resolvePlayableURL(from: item, playerId: playerId) {
                return url
            }
        }
        return nil
    }

    private func isMuxedMP4(_ item: [String: Any]) -> Bool {
        guard let mime = item["mimeType"] as? String else { return false }
        let lower = mime.lowercased()
        // Expect container mp4 with both video (avc1) and audio (mp4a) codecs.
        return lower.contains("video/mp4")
            && lower.contains("avc1")
            && lower.contains("mp4a")
            && (item["url"] != nil || item["signatureCipher"] != nil || item["cipher"] != nil)
    }

    private func extractPlayerResponseJSON(from html: String) -> String? {
        let pattern = #"ytInitialPlayerResponse\s*=\s*(\{.*?\});"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let jsonRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[jsonRange])
    }

    private func iosUserAgent(countryCode: String) -> String {
        "com.google.ios.youtube/\(iosClientVersion)(\(iosDeviceModel); U; CPU iOS \(iosUserAgentVersion) like Mac OS X; \(countryCode))"
    }

    private func extractPlayerId(from root: [String: Any]) -> String? {
        if let assets = root["assets"] as? [String: Any],
           let js = assets["js"] as? String,
           let id = parsePlayerId(from: js) {
            return id
        }
        if let playerConfig = root["playerConfig"] as? [String: Any],
           let js = playerConfig["jsUrl"] as? String,
           let id = parsePlayerId(from: js) {
            return id
        }
        return nil
    }

    private func resolvePlayerId(videoId: String, root: [String: Any]) async -> String? {
        if let direct = extractPlayerId(from: root) {
            return direct
        }
        return await fetchPlayerIdFromWatchPage(videoId: videoId)
    }

    private func fetchPlayerIdFromWatchPage(videoId: String) async -> String? {
        let watchURLString = "https://www.youtube.com/watch?v=\(videoId)"
        guard let url = URL(string: watchURLString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard var html = String(data: data, encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: "\\u002F", with: "/")
            return parsePlayerId(from: html)
        } catch {
            return nil
        }
    }

    private func parsePlayerId(from jsURL: String) -> String? {
        let pattern = #"/s/player/([a-zA-Z0-9_-]{8,})/"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(jsURL.startIndex..., in: jsURL)
        guard let match = regex.firstMatch(in: jsURL, options: [], range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: jsURL) else {
            return nil
        }
        let full = String(jsURL[idRange])
        if full.count > 8 {
            return String(full.prefix(8))
        }
        return full
    }

    private func resolvePlayableURL(from item: [String: Any], playerId: String?) async -> URL? {
        if let urlString = item["url"] as? String, let url = URL(string: urlString) {
            return await decodeThrottlingIfNeeded(url: url, playerId: playerId)
        }
        let cipher = item["signatureCipher"] as? String ?? item["cipher"] as? String
        guard let cipher else { return nil }
        return await decodeCipherURL(cipher, playerId: playerId)
    }

    private func decodeCipherURL(_ cipher: String, playerId: String?) async -> URL? {
        let params = parseQueryString(cipher)
        guard let urlString = params["url"], let baseURL = URL(string: urlString) else {
            return nil
        }
        guard let playerId else {
            return nil
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []

        // Apply extra params from cipher (except signature fields).
        for (key, value) in params where key != "url" && key != "s" && key != "sp" {
            setQueryItem(&queryItems, name: key, value: value)
        }

        if let s = params["s"] {
            do {
                let decoded = try await decodeParam(playerId: playerId, type: "sig", value: s)
                let sp = params["sp"] ?? "signature"
                setQueryItem(&queryItems, name: sp, value: decoded)
            } catch {
                return nil
            }
        }

        components.queryItems = queryItems
        guard let signedURL = components.url else { return nil }
        return await decodeThrottlingIfNeeded(url: signedURL, playerId: playerId)
    }

    private func decodeThrottlingIfNeeded(url: URL, playerId: String?) async -> URL {
        guard let playerId else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        guard let nValue = queryItems.first(where: { $0.name == "n" })?.value else {
            return url
        }
        do {
            let decoded = try await decodeParam(playerId: playerId, type: "n", value: nValue)
            setQueryItem(&queryItems, name: "n", value: decoded)
            components.queryItems = queryItems
            return components.url ?? url
        } catch {
            return url
        }
    }

    func decodeThrottlingURL(_ url: URL, playerId: String?) async -> URL {
        await decodeThrottlingIfNeeded(url: url, playerId: playerId)
    }

    private func decodeParam(playerId: String, type: String, value: String) async throws -> String {
        let cacheKey = "\(playerId):\(type):\(value)"
        if let cached = decoderCache[cacheKey] {
            return cached
        }

        guard var components = URLComponents(string: decoderBaseURL) else {
            throw PlaybackError.decoderFailed
        }
        components.queryItems = [
            URLQueryItem(name: "player", value: playerId),
            URLQueryItem(name: type, value: value)
        ]
        guard let url = components.url else { throw PlaybackError.decoderFailed }

        var request = URLRequest(url: url)
        request.setValue(decoderUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaybackError.decoderFailed
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "result",
              let responses = root["responses"] as? [[String: Any]],
              let first = responses.first,
              (first["type"] as? String) == "result",
              let dataDict = first["data"] as? [String: Any],
              let decoded = dataDict[value] as? String,
              !decoded.isEmpty else {
            throw PlaybackError.decoderFailed
        }

        decoderCache[cacheKey] = decoded
        return decoded
    }

    private func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = query.split(separator: "&")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]) : ""
            let decodedKey = key.removingPercentEncoding ?? key
            let decodedValue = value.removingPercentEncoding ?? value
            result[decodedKey] = decodedValue
        }
        return result
    }

    private func setQueryItem(_ items: inout [URLQueryItem], name: String, value: String) {
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = value
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
    }

    private func streamHeaders(videoId: String, userAgent: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": "en-US,en;q=0.9"
        ]

        // Prevent consent gating on some networks/regions.
        headers["Cookie"] = "CONSENT=YES+1"

        return headers
    }
}

private extension YouTubePlaybackService {
    func logStreamingDataIfNeeded(root: [String: Any], source: String) {
#if DEBUG
        guard let streamingData = root["streamingData"] as? [String: Any] else {
            print("[YouTubePlaybackService] \(source): no streamingData")
            return
        }

        if let hls = streamingData["hlsManifestUrl"] as? String {
            print("[YouTubePlaybackService] \(source): hlsManifestUrl = \(hls)")
        }
        if let dash = streamingData["dashManifestUrl"] as? String {
            print("[YouTubePlaybackService] \(source): dashManifestUrl = \(dash)")
        }

        if let formats = streamingData["formats"] as? [[String: Any]] {
            for (idx, item) in formats.enumerated() {
                let itag = item["itag"] as? Int ?? -1
                let mime = item["mimeType"] as? String ?? "unknown"
                let url = item["url"] as? String ?? "no-url"
                let cipher = item["signatureCipher"] as? String ?? item["cipher"] as? String ?? "no-cipher"
                print("[YouTubePlaybackService] \(source): formats[\(idx)] itag=\(itag) mime=\(mime) url=\(url) cipher=\(cipher)")
            }
        }

        if let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for (idx, item) in adaptive.enumerated() {
                let itag = item["itag"] as? Int ?? -1
                let mime = item["mimeType"] as? String ?? "unknown"
                let url = item["url"] as? String ?? "no-url"
                let cipher = item["signatureCipher"] as? String ?? item["cipher"] as? String ?? "no-cipher"
                print("[YouTubePlaybackService] \(source): adaptive[\(idx)] itag=\(itag) mime=\(mime) url=\(url) cipher=\(cipher)")
            }
        }
#endif
    }
}
