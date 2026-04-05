import Foundation
import JavaScriptCore

// MARK: - YouTubePlaybackService
// Client waterfall: ANDROID_VR → ANDROID → IOS
//
// References:
//   yt-dlp default clients (2025): android_vr, ios
//   github.com/TeamNewPipe/NewPipeExtractor — YoutubeStreamExtractor.java
//   github.com/zerodytrash/YouTube-Internal-Clients

actor YouTubePlaybackService {
    static let shared = YouTubePlaybackService()

    private let session: URLSession

    // ── IOS client (primary — returns HLS, no PO token required) ─────────────
    private let iosClientName    = "IOS"
    private let iosClientVersion = "20.03.02"
    private let iosClientNameInt = "5"
    private let iosUserAgent     = "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)"

    // ── ANDROID_VR client (secondary — yt-dlp default, no PO token required) ─
    private let vrClientName    = "ANDROID_VR"
    private let vrClientVersion = "1.60.19"
    private let vrClientNameInt = "28"
    private let vrSdkVersion    = 32
    private let vrUserAgent     = "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    // ── ANDROID client (fallback — updated version) ───────────────────────────
    private let androidClientName    = "ANDROID"
    private let androidClientVersion = "20.10.38"
    private let androidClientNameInt = "3"
    private let androidSdkVersion    = 34
    private let androidUserAgent     = "com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip"

    // Base InnerTube endpoint (no API key — avoids stale-key rejections)
    private let playerEndpoint = "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false"

    // Cached visitor data (obtained once per session)
    private var visitorData: String?
    private var isFetchingVisitorData = false

    // Local n-param decoder cache
    private var playerJSCache: [String: String] = [:]   // playerId → JS text
    private var nDecoderCache: [String: String] = [:]   // playerId → func body

    private let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private let resolveTimeout: TimeInterval = 8

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public types

    struct PlaybackData {
        let streamURL: URL
        let title: String?
        let channelName: String?
        let channelId: String?
        let description: String?
        let headers: [String: String]
        let playerId: String?
        let resolvedClient: String
    }

    enum ResolveStrategy {
        case fastest
        case exclude(client: String)
    }

    enum PlaybackError: LocalizedError {
        case invalidURL
        case invalidResponse
        case invalidJSON
        case httpStatus(Int, String)
        case noPlayableStream
        case notPlayable(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:              return "Не удалось сформировать запрос."
            case .invalidResponse:         return "Сервер вернул некорректный ответ."
            case .invalidJSON:             return "Не удалось разобрать ответ плеера."
            case .httpStatus(let c, _):    return "Ошибка загрузки видео: HTTP \(c)."
            case .noPlayableStream:        return "Для этого видео не найден поток воспроизведения."
            case .notPlayable(let reason): return "Видео недоступно: \(reason)"
            }
        }
    }

    // MARK: - Public API

    /// Tries ANDROID_VR → ANDROID → IOS in order. First success wins.
    func resolve(videoId: String, strategy: ResolveStrategy = .fastest) async throws -> PlaybackData {
        startVisitorDataFetchIfNeeded()

        if case .exclude(let excludedClient) = strategy {
            return try await resolveWithExcludedClient(videoId: videoId, excludedClient: excludedClient)
        }

        var failures: [String] = []
        if let result = await withTaskGroup(of: ClientAttempt.self, returning: PlaybackData?.self) { group in
            group.addTask {
                do {
                    return .success(label: "ANDROID_VR", data: try await self.resolveViaAndroidVR(videoId: videoId))
                } catch {
                    return .failure(label: "ANDROID_VR", reason: error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    return .success(label: "ANDROID", data: try await self.resolveViaAndroid(videoId: videoId))
                } catch {
                    return .failure(label: "ANDROID", reason: error.localizedDescription)
                }
            }

            while let attempt = await group.next() {
                switch attempt {
                case .success(let label, let data):
#if DEBUG
                    print("[YT] resolved via \(label) client")
#endif
                    group.cancelAll()
                    return data
                case .failure(let label, let reason):
                    failures.append("\(label): \(reason)")
                }
            }
            return nil
        } {
            return result
        }

        // 3. IOS client — last resort (can hit 403 on HLS segments for some videos/IPs).
#if DEBUG
        if !failures.isEmpty {
            print("[YT] primary clients failed: \(failures.joined(separator: " | "))")
        }
        print("[YT] falling back to IOS client")
#endif
        return try await resolveViaIOS(videoId: videoId)
    }

    func warmup() {
        startVisitorDataFetchIfNeeded()
    }

    private func startVisitorDataFetchIfNeeded() {
        guard visitorData == nil, !isFetchingVisitorData else { return }
        isFetchingVisitorData = true

        Task {
            let fetched = await self.fetchVisitorData()
            self.finishVisitorDataFetch(fetched)
        }
    }

    private func finishVisitorDataFetch(_ fetched: String?) {
        if visitorData == nil {
            visitorData = fetched
        }
        isFetchingVisitorData = false
#if DEBUG
        print("[YT] visitorData=\(visitorData ?? "nil")")
#endif
    }

    /// Called from HLSProxy — decode n-param locally.
    func decodeThrottlingURL(_ url: URL, playerId: String?) async -> URL {
        await decodeThrottlingIfNeeded(url: url, playerId: playerId)
    }

    // MARK: - Visitor Data

    private func fetchVisitorData() async -> String? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": iosClientName,
                    "clientVersion": iosClientVersion,
                    "hl": "en", "gl": "US"
                ]
            ],
            "browseId": "FEwhat_to_watch"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await session.data(for: req)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ctx = root["responseContext"] as? [String: Any],
                  let vd = ctx["visitorData"] as? String else { return nil }
            return vd
        } catch { return nil }
    }

    // MARK: - IOS Client

    private func resolveViaIOS(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(iosUserAgent,        forHTTPHeaderField: "User-Agent")
        req.setValue(iosClientNameInt,    forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(iosClientVersion,    forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":    iosClientName,
            "clientVersion": iosClientVersion,
            "deviceMake":    "Apple",
            "deviceModel":   "iPhone16,2",
            "osName":        "iPhone",
            "osVersion":     "18.2.1.22D82",
            "hl": "en", "gl": "US", "utcOffsetMinutes": 0
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload: [String: Any] = [
            "context": ["client": clientCtx, "user": ["lockedSafetyMode": false]],
            "videoId": videoId,
            "cpn": randomCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/IOS] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = iosStreamHeaders(videoId: videoId)


        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
#if DEBUG
            print("[YT/IOS] using HLS: \(decoded)")
#endif
            return PlaybackData(streamURL: decoded, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: iosClientName)
        }

        // IOS sometimes returns adaptive formats instead of HLS
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            return PlaybackData(streamURL: muxURL, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: iosClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - ANDROID_VR Client

    private func resolveViaAndroidVR(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(vrUserAgent,         forHTTPHeaderField: "User-Agent")
        req.setValue(vrClientNameInt,     forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(vrClientVersion,     forHTTPHeaderField: "X-YouTube-Client-Version")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":       vrClientName,
            "clientVersion":    vrClientVersion,
            "androidSdkVersion": vrSdkVersion,
            "hl": "en", "gl": "US", "utcOffsetMinutes": 0
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload: [String: Any] = [
            "context": ["client": clientCtx, "user": ["lockedSafetyMode": false]],
            "videoId": videoId,
            "cpn": randomCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/ANDROID_VR] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String
        let isLive    = details?["isLiveContent"] as? Bool ?? false

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = androidStreamHeaders(videoId: videoId, userAgent: vrUserAgent)

        // Muxed MP4 first — direct URL, no HLS proxy, far less 403-prone
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if !isLive, let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            return PlaybackData(streamURL: muxURL, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: vrClientName)
        }

        // HLS fallback (live streams, or no muxed formats available)
        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
            return PlaybackData(streamURL: decoded, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: vrClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - ANDROID Client (fallback)

    private func resolveViaAndroid(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",   forHTTPHeaderField: "Content-Type")
        req.setValue(androidUserAgent,     forHTTPHeaderField: "User-Agent")
        req.setValue(androidClientNameInt, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(androidClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":        androidClientName,
            "clientVersion":     androidClientVersion,
            "androidSdkVersion": androidSdkVersion,
            "hl": "en", "gl": "US", "utcOffsetMinutes": 0
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload: [String: Any] = [
            "context": ["client": clientCtx, "user": ["lockedSafetyMode": false]],
            "videoId": videoId,
            "cpn": randomCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/ANDROID] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String
        let isLive    = details?["isLiveContent"] as? Bool ?? false

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = androidStreamHeaders(videoId: videoId, userAgent: androidUserAgent)

        // Muxed MP4 first — direct URL, no HLS proxy, far less 403-prone
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if !isLive, let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            return PlaybackData(streamURL: muxURL, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: androidClientName)
        }

        // HLS fallback (live streams, or no muxed formats available)
        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
            return PlaybackData(streamURL: decoded, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: androidClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - Shared request helper

    private func fetchPlayerRoot(request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaybackError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw PlaybackError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }
        return root
    }

    private func checkPlayability(root: [String: Any]) throws {
        guard let ps = root["playabilityStatus"] as? [String: Any],
              let status = ps["status"] as? String else { return }
        guard status == "OK" else {
            let reason = ps["reason"] as? String ?? status
            throw PlaybackError.notPlayable(reason)
        }
    }

    // MARK: - Stream selection

    private func pickBestMuxedURL(
        from formats: [[String: Any]],
        playerId: String?,
        startupPreferred: Bool
    ) async -> URL? {
        let muxed = formats.filter {
            guard let mime = $0["mimeType"] as? String else { return false }
            let m = mime.lowercased()
            return m.contains("video/mp4") && m.contains("avc1") && m.contains("mp4a")
        }
        let ranked = muxed.sorted { lhs, rhs in
            formatScore(lhs, startupPreferred: startupPreferred) > formatScore(rhs, startupPreferred: startupPreferred)
        }
        for item in ranked.prefix(6) {
            guard let url = await resolveURL(from: item, playerId: playerId) else { continue }
            if hasRateBypass(url) { return url }
        }
        for item in ranked {
            if let url = await resolveURL(from: item, playerId: playerId) { return url }
        }
        return nil
    }

    private func formatScore(_ item: [String: Any], startupPreferred: Bool) -> Int {
        let width = item["width"] as? Int ?? 0
        let bitrate = item["bitrate"] as? Int ?? 0
        let itag = item["itag"] as? Int ?? -1
        var score = 0
        if itag == 18 { score += 140 }
        if startupPreferred {
            if width <= 480 { score += 90 }
            else if width <= 720 { score += 55 }
            else { score += 20 }
            score += min(bitrate / 80_000, 40)
        } else {
            score += min(width / 8, 180)
            score += min(bitrate / 60_000, 80)
        }
        return score
    }

    private func hasRateBypass(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return false
        }
        return items.contains { $0.name == "ratebypass" && ($0.value ?? "").lowercased() == "yes" }
    }

    private func resolveURL(from item: [String: Any], playerId: String?) async -> URL? {
        guard let urlStr = item["url"] as? String, let url = URL(string: urlStr) else { return nil }
        return await decodeThrottlingIfNeeded(url: url, playerId: playerId)
    }

    // MARK: - n-param throttling — local JavaScript decoder

    private func decodeThrottlingIfNeeded(url: URL, playerId: String?) async -> URL {
        guard let playerId else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard let nValue = items.first(where: { $0.name == "n" })?.value else { return url }

        do {
            let decoded = try await decodeNParam(nValue, playerId: playerId)
            if let index = items.firstIndex(where: { $0.name == "n" }) {
                items[index].value = decoded
            } else {
                items.append(URLQueryItem(name: "n", value: decoded))
            }
            components.queryItems = items
            return components.url ?? url
        } catch {
#if DEBUG
            print("[NDecoder] failed: \(error.localizedDescription) — using raw URL (may throttle)")
#endif
            return url
        }
    }

    private func decodeNParam(_ n: String, playerId: String) async throws -> String {
        let funcBody = try await getNDecoderFunction(playerId: playerId)
        return try runInJS(funcBody: funcBody, input: n)
    }

    private func getNDecoderFunction(playerId: String) async throws -> String {
        if let cached = nDecoderCache[playerId] { return cached }
        let js = try await fetchPlayerJS(playerId: playerId)
        let body = try extractNDecoderBody(from: js)
        nDecoderCache[playerId] = body
        return body
    }

    private func fetchPlayerJS(playerId: String) async throws -> String {
        if let cached = playerJSCache[playerId] { return cached }
        let urlStr = "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js"
        guard let url = URL(string: urlStr) else { throw NSError(domain: "NDecoder", code: 1) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NSError(domain: "NDecoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty player.js"])
        }
        playerJSCache[playerId] = text
        return text
    }

    /// Mirrors YoutubeThrottlingParameterUtils — 8 regex patterns for resilience.
    private func extractNDecoderBody(from js: String) throws -> String {
        let callPatterns: [(String, Bool)] = [
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\[(\d+)\]\(b\)"#, true),
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\[0\]\(b\)"#,    true),
            (#"b=([a-zA-Z$_][\w$]*)\[0\]\(b\),c\.set\("n",b\)"#,       true),
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\(b\)"#,          false),
            (#"b=([a-zA-Z$_][\w$]*)\(b\),c\.set\("n",b\)"#,            false),
        ]

        for (pattern, isArray) in callPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: js) else { continue }

            let name = String(js[nameRange])
            let idx: Int = {
                guard isArray, match.numberOfRanges >= 3,
                      let r = Range(match.range(at: 2), in: js) else { return 0 }
                return Int(js[r]) ?? 0
            }()

            if isArray {
                if let body = extractFunctionFromArray(named: name, index: idx, js: js) {
#if DEBUG
                    print("[NDecoder] found via array pattern '\(name)[\(idx)]'")
#endif
                    return body
                }
            } else {
                if let body = extractNamedFunction(named: name, js: js) {
#if DEBUG
                    print("[NDecoder] found via direct pattern '\(name)'")
#endif
                    return body
                }
            }
        }

        throw NSError(domain: "NDecoder", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "n-decoder not found in player.js"])
    }

    private func extractFunctionFromArray(named name: String, index: Int, js: String) -> String? {
        for prefix in ["var \(name)=[", "\(name)=["] {
            guard let r = js.range(of: prefix) else { continue }
            if let body = extractFunctionAtIndex(js: js, arrayStart: r.upperBound, targetIndex: index) {
                return body
            }
        }
        return nil
    }

    private func extractFunctionAtIndex(js: String, arrayStart: String.Index, targetIndex: Int) -> String? {
        var i = arrayStart
        var count = 0
        while i < js.endIndex {
            if js[i] == "]" { break }
            let kw = "function"
            if js[i...].hasPrefix(kw) {
                if count == targetIndex {
                    return extractBalancedFunction(js: js, at: i)
                }
                count += 1
                if let end = findClosingBrace(js: js, from: i) { i = end; continue }
            }
            i = js.index(after: i)
        }
        return nil
    }

    private func extractNamedFunction(named name: String, js: String) -> String? {
        for prefix in ["var \(name)=function", "\(name)=function"] {
            guard let r = js.range(of: prefix),
                  let kwRange = js.range(of: "function", range: r.lowerBound..<js.endIndex) else { continue }
            return extractBalancedFunction(js: js, at: kwRange.lowerBound)
        }
        return nil
    }

    private func extractBalancedFunction(js: String, at start: String.Index) -> String? {
        var i = start
        while i < js.endIndex, js[i] != "{" { i = js.index(after: i) }
        guard let end = findClosingBrace(js: js, from: i) else { return nil }
        return String(js[start..<end])
    }

    private func findClosingBrace(js: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inStr: Character? = nil
        var escaped = false
        var i = start
        while i < js.endIndex {
            let c = js[i]
            defer { i = js.index(after: i) }
            if escaped              { escaped = false; continue }
            if c == "\\" && inStr != nil { escaped = true; continue }
            if let s = inStr        { if c == s { inStr = nil }; continue }
            if c == "\"" || c == "'" || c == "`" { inStr = c; continue }
            if c == "{"             { depth += 1 }
            else if c == "}"        { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private func runInJS(funcBody: String, input: String) throws -> String {
        let ctx = JSContext()!
        var jsErr: JSValue?
        ctx.exceptionHandler = { _, e in jsErr = e }

        let safe = input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
        let script = "(function(){ var f=\(funcBody); return f('\(safe)'); })()"
        let result = ctx.evaluateScript(script)

        if let e = jsErr {
            throw NSError(domain: "NDecoder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "JS error: \(e.toString() ?? "?")"])
        }
        guard let out = result?.toString(), out != "undefined", out != "null", !out.isEmpty else {
            throw NSError(domain: "NDecoder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "JS returned empty"])
        }
        return out
    }

    // MARK: - Player ID extraction

    private func extractPlayerId(from root: [String: Any]) -> String? {
        if let assets = root["assets"] as? [String: Any],
           let js = assets["js"] as? String { return parsePlayerId(from: js) }
        if let cfg = root["playerConfig"] as? [String: Any],
           let js = cfg["jsUrl"] as? String { return parsePlayerId(from: js) }
        return nil
    }

    private func fetchPlayerIdFromWatchPage(videoId: String) async -> String? {
        // Embed page is simpler HTML, less likely to be bot-detected, always contains player config
        if let id = await fetchPlayerIdFromPage(
            urlString: "https://www.youtube.com/embed/\(videoId)",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        ) { return id }

        // Fallback to full watch page
        return await fetchPlayerIdFromPage(
            urlString: "https://www.youtube.com/watch?v=\(videoId)",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        )
    }

    private func fetchPlayerIdFromPage(urlString: String, userAgent: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("CONSENT=YES+cb.20231221-07-p0.en+FX+; SOCS=CAE=", forHTTPHeaderField: "Cookie")
        do {
            let (data, _) = try await session.data(for: req)
            guard var html = String(data: data, encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: "\\u002F", with: "/")
            return parsePlayerId(from: html)
        } catch { return nil }
    }

    private func parsePlayerId(from text: String) -> String? {
        let pattern = #"/s/player/([a-fA-F0-9]{8,})/"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(String(text[range]).prefix(8))
    }

    private func requiresNDecoding(in streaming: [String: Any]?) -> Bool {
        guard let streaming else { return false }
        let formats = (streaming["formats"] as? [[String: Any]] ?? [])
            + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])

        for format in formats {
            if let urlString = format["url"] as? String,
               urlString.contains("n=") {
                return true
            }
            if let cipher = format["signatureCipher"] as? String,
               cipher.contains("n%3D") || cipher.contains("n=") {
                return true
            }
            if let cipher = format["cipher"] as? String,
               cipher.contains("n%3D") || cipher.contains("n=") {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private func randomCPN() -> String {
        String((0..<16).map { _ in nonceAlphabet.randomElement()! })
    }

    private func iosStreamHeaders(videoId: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent":      iosUserAgent,
            "Origin":          "https://www.youtube.com",
            "Referer":         "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let vd = visitorData { h["X-Goog-Visitor-Id"] = vd }
        return h
    }

    private func androidStreamHeaders(videoId: String, userAgent: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent":      userAgent,
            "Origin":          "https://www.youtube.com",
            "Referer":         "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let vd = visitorData { h["X-Goog-Visitor-Id"] = vd }
        return h
    }

    private func resolveWithExcludedClient(videoId: String, excludedClient: String) async throws -> PlaybackData {
        var failures: [String] = []

        if excludedClient != vrClientName {
            do { return try await resolveViaAndroidVR(videoId: videoId) }
            catch { failures.append("\(vrClientName): \(error.localizedDescription)") }
        }
        if excludedClient != androidClientName {
            do { return try await resolveViaAndroid(videoId: videoId) }
            catch { failures.append("\(androidClientName): \(error.localizedDescription)") }
        }
        if excludedClient != iosClientName {
            do { return try await resolveViaIOS(videoId: videoId) }
            catch { failures.append("\(iosClientName): \(error.localizedDescription)") }
        }

        throw PlaybackError.notPlayable(failures.joined(separator: " | "))
    }
}

// MARK: - Debug logging

#if DEBUG
private extension YouTubePlaybackService {
    func logStreams(root: [String: Any]) {
        guard let s = root["streamingData"] as? [String: Any] else {
            print("[YT] no streamingData"); return
        }
        print("[YT] hlsManifestUrl=\(s["hlsManifestUrl"] ?? "nil")")
        print("[YT] dashManifestUrl=\(s["dashManifestUrl"] ?? "nil")")
        if let formats = s["formats"] as? [[String: Any]] {
            for f in formats {
                print("[YT] format itag=\(f["itag"] ?? "?") mime=\(f["mimeType"] ?? "?") hasURL=\(f["url"] != nil)")
            }
        }
    }
}
#endif

private enum ClientAttempt {
    case success(label: String, data: YouTubePlaybackService.PlaybackData)
    case failure(label: String, reason: String)
}
