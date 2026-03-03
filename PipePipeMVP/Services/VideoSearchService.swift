import Foundation

protocol VideoSearchServicing {
    func search(query: String) async throws -> [VideoItem]
    func resolvePlayback(videoId: String) async throws -> PlaybackSource
    func fetchChannelVideos(channelId: String, limit: Int) async throws -> [VideoItem]
}

struct PlaybackSource {
    let url: URL
    let isHLS: Bool
}

enum VideoSearchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unableToExtractInnerTubeConfig
    case streamUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to build request URL."
        case .invalidResponse:
            return "Unexpected server response."
        case .unableToExtractInnerTubeConfig:
            return "Failed to extract YouTube InnerTube configuration."
        case .streamUnavailable:
            return "No playable stream was found for this video."
        }
    }
}

struct VideoSearchService: VideoSearchServicing {
    private let session: URLSession
    private let configStore = InnerTubeConfigStore()

    struct InnerTubeConfig {
        let apiKey: String
        let clientVersion: String
    }

    private enum IOSClient {
        static let version = "21.03.2"
        static let deviceModel = "iPhone16,2"
        static let osVersion = "18.7.2.22H124"
        static let userAgentVersion = "18_7_2"
        static let apiKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String) async throws -> [VideoItem] {
        let config = try await configStore.getConfig(session: session)

        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "key", value: config.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let url = components?.url else {
            throw VideoSearchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        let body = Self.makeSearchBody(query: query, clientVersion: config.clientVersion)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw VideoSearchError.invalidResponse
        }

        return try Self.parseSearchResponse(data)
    }

    func resolvePlayback(videoId: String) async throws -> PlaybackSource {
        var components = URLComponents(string: "https://youtubei.googleapis.com/youtubei/v1/player")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "id", value: videoId),
            URLQueryItem(name: "t", value: Self.randomToken(length: 12))
        ]

        guard let baseUrl = components?.url,
              var playerURL = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) else {
            throw VideoSearchError.invalidURL
        }

        var existingItems = playerURL.queryItems ?? []
        existingItems.append(URLQueryItem(name: "key", value: IOSClient.apiKey))
        playerURL.queryItems = existingItems

        guard let requestURL = playerURL.url else {
            throw VideoSearchError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.iosUserAgent(countryCode: "US"), forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")

        let body = Self.makeIOSPlayerBody(videoId: videoId)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoSearchError.invalidResponse
        }

        if let source = Self.parsePlayerSource(json) {
            return source
        }

        throw VideoSearchError.streamUnavailable
    }

    func fetchChannelVideos(channelId: String, limit: Int = 20) async throws -> [VideoItem] {
        let config = try await configStore.getConfig(session: session)
        // Prefer the "Videos" tab endpoint first, then fallback to default browse.
        if let json = try await requestBrowse(
            channelId: channelId,
            apiKey: config.apiKey,
            clientVersion: config.clientVersion,
            params: "EgZ2aWRlb3PyBgQKAjoA"
        ) {
            let videos = Self.parseBrowseVideos(json, limit: limit, channelId: channelId)
            if !videos.isEmpty { return videos }
        }

        if let json = try await requestBrowse(
            channelId: channelId,
            apiKey: config.apiKey,
            clientVersion: config.clientVersion,
            params: nil
        ) {
            return Self.parseBrowseVideos(json, limit: limit, channelId: channelId)
        }

        return []
    }

    private func requestBrowse(
        channelId: String,
        apiKey: String,
        clientVersion: String,
        params: String?
    ) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let url = components?.url else {
            throw VideoSearchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")

        let body = Self.makeBrowseBody(
            channelId: channelId,
            clientVersion: clientVersion,
            params: params
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func makeSearchBody(query: String, clientVersion: String) -> [String: Any] {
        [
            "context": [
                "client": [
                    "hl": "en",
                    "gl": "US",
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "originalUrl": "https://www.youtube.com",
                    "platform": "DESKTOP",
                    "utcOffsetMinutes": 0
                ],
                "request": [
                    "internalExperimentFlags": [],
                    "useSsl": true
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "query": query
        ]
    }

    private static func makeBrowseBody(
        channelId: String,
        clientVersion: String,
        params: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "context": [
                "client": [
                    "hl": "en",
                    "gl": "US",
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "originalUrl": "https://www.youtube.com",
                    "platform": "DESKTOP",
                    "utcOffsetMinutes": 0
                ],
                "request": [
                    "internalExperimentFlags": [],
                    "useSsl": true
                ]
            ],
            "browseId": channelId
        ]
        if let params {
            body["params"] = params
        }
        return body
    }

    private static func makeIOSPlayerBody(videoId: String) -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": IOSClient.version,
                    "deviceMake": "Apple",
                    "deviceModel": IOSClient.deviceModel,
                    "osName": "iOS",
                    "osVersion": IOSClient.osVersion,
                    "hl": "en",
                    "gl": "US",
                    "utcOffsetMinutes": 0
                ],
                "request": [
                    "internalExperimentFlags": [],
                    "useSsl": true
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "videoId": videoId,
            "cpn": randomToken(length: 16),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
    }

    private static func parsePlayerSource(_ json: [String: Any]) -> PlaybackSource? {
        if let streamingData = json["streamingData"] as? [String: Any] {
            if let hlsManifestURL = streamingData["hlsManifestUrl"] as? String,
               let url = URL(string: hlsManifestURL) {
                return PlaybackSource(url: url, isHLS: true)
            }

            if let formats = streamingData["formats"] as? [[String: Any]] {
                for item in formats {
                    if let streamURL = item["url"] as? String,
                       let url = URL(string: streamURL) {
                        return PlaybackSource(url: url, isHLS: false)
                    }
                }
            }
        }

        return nil
    }

    private static func parseSearchResponse(_ data: Data) throws -> [VideoItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoSearchError.invalidResponse
        }

        let contents = (((((json["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"]
            as? [String: Any])?["primaryContents"] as? [String: Any])?["sectionListRenderer"]
            as? [String: Any])?["contents"] as? [[String: Any]]) ?? []

        var items: [VideoItem] = []
        for section in contents {
            guard let itemSection = section["itemSectionRenderer"] as? [String: Any],
                  let renderers = itemSection["contents"] as? [[String: Any]] else {
                continue
            }
            for renderer in renderers {
                guard let video = renderer["videoRenderer"] as? [String: Any],
                      let id = video["videoId"] as? String else {
                    continue
                }

                let title = textFromRunsObject(video["title"]) ?? "Unknown title"
                let channel = textFromRunsObject(video["ownerText"]) ?? "Unknown channel"
                let channelId = channelId(from: video["ownerText"])
                let thumb = thumbnailURL(from: video["thumbnail"])
                let duration = textFromRunsObject(video["lengthText"])
                let published = textFromRunsObject(video["publishedTimeText"])
                let isLive = isLiveVideo(video)
                items.append(VideoItem(
                    id: id,
                    title: title,
                    channelTitle: channel,
                    channelID: channelId,
                    thumbnailURL: thumb,
                    durationText: duration,
                    publishedText: published,
                    isLive: isLive
                ))
            }
        }
        return items
    }

    private static func iosUserAgent(countryCode: String) -> String {
        "com.google.ios.youtube/\(IOSClient.version)(\(IOSClient.deviceModel); U; CPU iOS \(IOSClient.userAgentVersion) like Mac OS X; \(countryCode))"
    }

    private static func randomToken(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private static func textFromRunsObject(_ source: Any?) -> String? {
        guard let object = source as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String {
            return simple
        }
        guard let runs = object["runs"] as? [[String: Any]] else { return nil }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    private static func channelId(from source: Any?) -> String? {
        guard let object = source as? [String: Any],
              let runs = object["runs"] as? [[String: Any]] else {
            return nil
        }

        for run in runs {
            guard let endpoint = run["navigationEndpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String else {
                continue
            }
            return browseId
        }
        return nil
    }

    private static func thumbnailURL(from source: Any?) -> URL? {
        guard let object = source as? [String: Any],
              let thumbs = object["thumbnails"] as? [[String: Any]],
              let urlString = thumbs.last?["url"] as? String else {
            return nil
        }
        return URL(string: urlString)
    }

    private static func isLiveVideo(_ renderer: [String: Any]) -> Bool {
        if let badges = renderer["badges"] as? [[String: Any]] {
            for badge in badges {
                if let metadata = badge["metadataBadgeRenderer"] as? [String: Any],
                   let style = metadata["style"] as? String,
                   style.contains("LIVE") {
                    return true
                }
            }
        }

        if let overlays = renderer["thumbnailOverlays"] as? [[String: Any]] {
            for overlay in overlays {
                if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let style = status["style"] as? String,
                   style.contains("LIVE") {
                    return true
                }
            }
        }

        return false
    }

    private static func parseBrowseVideos(_ json: [String: Any], limit: Int, channelId: String) -> [VideoItem] {
        var collected: [VideoItem] = []
        collectVideoRenderers(in: json, output: &collected, channelId: channelId)
        return Array(collected.prefix(limit))
    }

    private static func collectVideoRenderers(in value: Any, output: inout [VideoItem], channelId: String) {
        if let dict = value as? [String: Any] {
            if let video = dict["videoRenderer"] as? [String: Any],
               let id = video["videoId"] as? String {
                let title = textFromRunsObject(video["title"]) ?? "Unknown title"
                let channel = textFromRunsObject(video["ownerText"]) ?? "Unknown channel"
                let thumb = thumbnailURL(from: video["thumbnail"])
                let duration = textFromRunsObject(video["lengthText"])
                let published = textFromRunsObject(video["publishedTimeText"])
                let isLive = isLiveVideo(video)
                output.append(VideoItem(
                    id: id,
                    title: title,
                    channelTitle: channel,
                    channelID: channelId,
                    thumbnailURL: thumb,
                    durationText: duration,
                    publishedText: published,
                    isLive: isLive
                ))
            }

            for child in dict.values {
                collectVideoRenderers(in: child, output: &output, channelId: channelId)
            }
            return
        }

        if let list = value as? [Any] {
            for child in list {
                collectVideoRenderers(in: child, output: &output, channelId: channelId)
            }
        }
    }
}

private actor InnerTubeConfigStore {
    private var cachedConfig: VideoSearchService.InnerTubeConfig?

    func getConfig(session: URLSession) async throws -> VideoSearchService.InnerTubeConfig {
        if let cachedConfig {
            return cachedConfig
        }

        if let config = try await extractFromServiceWorker(session: session) {
            cachedConfig = config
            return config
        }

        if let config = try await extractFromSearchHtml(session: session) {
            cachedConfig = config
            return config
        }

        throw VideoSearchError.unableToExtractInnerTubeConfig
    }

    private func extractFromServiceWorker(session: URLSession)
    async throws -> VideoSearchService.InnerTubeConfig? {
        guard let url = URL(string: "https://www.youtube.com/sw.js") else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseInnerTubeConfig(from: body)
    }

    private func extractFromSearchHtml(session: URLSession)
    async throws -> VideoSearchService.InnerTubeConfig? {
        guard let url = URL(string: "https://www.youtube.com/results?search_query=&ucbcb=1")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseInnerTubeConfig(from: body)
    }

    private func parseInnerTubeConfig(from text: String) -> VideoSearchService.InnerTubeConfig? {
        let apiKeyPatterns = [
            #"INNERTUBE_API_KEY":"([0-9A-Za-z_-]+)"#,
            #"innertubeApiKey":"([0-9A-Za-z_-]+)"#
        ]
        let versionPatterns = [
            #"INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9\.]+)"#,
            #"innertube_context_client_version":"([0-9\.]+)"#,
            #"client\.version=([0-9\.]+)"#
        ]

        guard let apiKey = matchFirst(patterns: apiKeyPatterns, in: text),
              let version = matchFirst(patterns: versionPatterns, in: text) else {
            return nil
        }

        return VideoSearchService.InnerTubeConfig(apiKey: apiKey, clientVersion: version)
    }

    private func matchFirst(patterns: [String], in text: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let resultRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[resultRange])
        }
        return nil
    }
}
