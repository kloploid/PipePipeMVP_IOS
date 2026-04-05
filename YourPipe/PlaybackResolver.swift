import Foundation

struct ResolvedPlayback {
    let streamURL: URL
    let title: String?
    let channelName: String?
    let channelId: String?
    let description: String?
    let headers: [String: String]
    let playerId: String?
    let sourceLabel: String
    let directClientLabel: String?
}

enum PlaybackResolveError: LocalizedError {
    case unableToResolve([String])

    var errorDescription: String? {
        switch self {
        case .unableToResolve(let errors):
            if errors.isEmpty {
                return "Не удалось получить поток воспроизведения."
            }
            return "Не удалось получить поток. " + errors.joined(separator: " | ")
        }
    }
}

private actor DirectYouTubePlaybackProvider {
    private let service: YouTubePlaybackService

    init(service: YouTubePlaybackService = .shared) {
        self.service = service
    }

    func resolve(videoId: String, excludingClient: String? = nil) async throws -> ResolvedPlayback {
        let data: YouTubePlaybackService.PlaybackData
        if let excludingClient, !excludingClient.isEmpty {
            data = try await service.resolve(videoId: videoId, strategy: .exclude(client: excludingClient))
        } else {
            data = try await service.resolve(videoId: videoId, strategy: .fastest)
        }
        let sourceLabel = "YouTube Direct (\(data.resolvedClient))"
        return ResolvedPlayback(
            streamURL: data.streamURL,
            title: data.title,
            channelName: data.channelName,
            channelId: data.channelId,
            description: data.description,
            headers: data.headers,
            playerId: data.playerId,
            sourceLabel: sourceLabel,
            directClientLabel: data.resolvedClient
        )
    }
}

private actor PipedPlaybackProvider {
    let sourceLabel = "Piped"

    private let session: URLSession
    private let instances: [URL]

    init(
        session: URLSession = .shared,
        instances: [URL] = [
            URL(string: "https://pipedapi.kavin.rocks")!,
            URL(string: "https://pipedapi.leptons.xyz")!,
            URL(string: "https://pipedapi.nosebs.ru")!,
            URL(string: "https://piped-api.privacy.com.de")!,
            URL(string: "https://pipedapi.adminforge.de")!,
            URL(string: "https://api.piped.private.coffee")!,
            URL(string: "https://pipedapi.drgns.space")!,
            URL(string: "https://pipedapi.owo.si")!,
            URL(string: "https://piped-api.codespace.cz")!,
            URL(string: "https://pipedapi.reallyaweso.me")!,
            URL(string: "https://pipedapi.darkness.services")!,
            URL(string: "https://pipedapi.orangenet.cc")!,
            URL(string: "https://api.piped.yt")!
        ]
    ) {
        self.session = session
        self.instances = instances
    }

    func resolve(videoId: String) async throws -> ResolvedPlayback {
        var failures: [String] = []
        for instance in instances {
            do {
                return try await resolve(videoId: videoId, instance: instance)
            } catch {
                failures.append("\(instance.host ?? instance.absoluteString): \(error.localizedDescription)")
            }
        }
        throw PlaybackResolveError.unableToResolve(failures)
    }

    private func resolve(videoId: String, instance: URL) async throws -> ResolvedPlayback {
        let endpoint = instance
            .appendingPathComponent("streams")
            .appendingPathComponent(videoId)
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "Piped",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }

        let dto = try JSONDecoder().decode(PipedStreamsResponse.self, from: data)

        guard let streamCandidate = selectStreamURL(from: dto),
              let streamURL = absoluteURL(from: streamCandidate, instance: instance) else {
            throw NSError(
                domain: "Piped",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No playable stream URL in response"]
            )
        }

        let channelId = normalizedChannelId(dto.uploaderURL)
        return ResolvedPlayback(
            streamURL: streamURL,
            title: dto.title,
            channelName: dto.uploader,
            channelId: channelId,
            description: dto.description,
            headers: [:],
            playerId: nil,
            sourceLabel: sourceLabel,
            directClientLabel: nil
        )
    }

    private func selectStreamURL(from dto: PipedStreamsResponse) -> String? {
        if let hls = dto.hls, !hls.isEmpty {
            return hls
        }

        let muxed = dto.videoStreams
            .filter { !$0.videoOnly }
            .sorted { lhs, rhs in
                let lq = lhs.qualityScore
                let rq = rhs.qualityScore
                if lq != rq { return lq > rq }
                return lhs.bitrate > rhs.bitrate
            }

        if let first = muxed.first {
            return first.url
        }
        return nil
    }

    private func absoluteURL(from value: String, instance: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: instance)?.absoluteURL
    }

    private func normalizedChannelId(_ uploaderURL: String?) -> String? {
        guard let uploaderURL, !uploaderURL.isEmpty else { return nil }
        if uploaderURL.hasPrefix("/channel/") {
            return String(uploaderURL.dropFirst("/channel/".count))
        }
        if let url = URL(string: uploaderURL),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           comps.path.hasPrefix("/channel/") {
            return String(comps.path.dropFirst("/channel/".count))
        }
        return nil
    }
}

actor PlaybackResolver {
    static let shared = PlaybackResolver()

    private let directProvider: DirectYouTubePlaybackProvider
    private let pipedProvider: PipedPlaybackProvider
    private var cache: [String: CachedResolvedPlayback] = [:]
    private var inflight: [String: Task<ResolvedPlayback, Error>] = [:]
    private var prefetchInflight: [String: Task<Void, Never>] = [:]

    private init() {
        self.directProvider = DirectYouTubePlaybackProvider()
        self.pipedProvider = PipedPlaybackProvider()
    }

    func resolve(
        videoId: String,
        mode: PlaybackSourceMode,
        forceRefresh: Bool = false,
        excludingDirectClient: String? = nil
    ) async throws -> ResolvedPlayback {
        let key = cacheKey(videoId: videoId, mode: mode)

        if !forceRefresh, let cached = cache[key], !cached.isExpired {
            return cached.playback
        }

        if !forceRefresh, let task = inflight[key] {
            return try await task.value
        }

        if forceRefresh {
            cache[key] = nil
            inflight[key]?.cancel()
            inflight[key] = nil
        }

        let task = Task<ResolvedPlayback, Error> {
            switch mode {
            case .auto:
                do {
                    return try await directProvider.resolve(videoId: videoId, excludingClient: excludingDirectClient)
                } catch {
                    let firstError = "YouTube Direct: \(error.localizedDescription)"
                    do {
                        return try await pipedProvider.resolve(videoId: videoId)
                    } catch {
                        let secondError = "Piped: \(error.localizedDescription)"
                        throw PlaybackResolveError.unableToResolve([firstError, secondError])
                    }
                }
            case .direct:
                do {
                    return try await directProvider.resolve(videoId: videoId, excludingClient: excludingDirectClient)
                } catch {
                    throw PlaybackResolveError.unableToResolve(["YouTube Direct: \(error.localizedDescription)"])
                }
            case .piped:
                do {
                    return try await pipedProvider.resolve(videoId: videoId)
                } catch {
                    throw PlaybackResolveError.unableToResolve(["Piped: \(error.localizedDescription)"])
                }
            }
        }

        inflight[key] = task

        do {
            let playback = try await task.value
            cache[key] = CachedResolvedPlayback(
                playback: playback,
                expiresAt: computeExpiryDate(from: playback.streamURL)
            )
            inflight[key] = nil
            return playback
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    func prefetch(videoId: String, mode: PlaybackSourceMode) async {
        let key = cacheKey(videoId: videoId, mode: mode)
        if let task = prefetchInflight[key] {
            await task.value
            return
        }

        let task = Task<Void, Never> {
            guard let playback = try? await self.resolve(videoId: videoId, mode: mode) else { return }
            await self.warmupFirstByte(for: playback)
        }
        prefetchInflight[key] = task
        await task.value
        prefetchInflight[key] = nil
    }

    private func cacheKey(videoId: String, mode: PlaybackSourceMode) -> String {
        "\(mode.rawValue):\(videoId)"
    }

    private func computeExpiryDate(from url: URL) -> Date {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let expireRaw = components.queryItems?.first(where: { $0.name == "expire" })?.value,
           let unix = TimeInterval(expireRaw) {
            // Keep a small safety margin.
            return Date(timeIntervalSince1970: unix - 30)
        }
        return Date().addingTimeInterval(120)
    }

    private func warmupFirstByte(for playback: ResolvedPlayback) async {
        var request = URLRequest(url: playback.streamURL, timeoutInterval: 3)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        let headers = effectiveHeadersForWarmup(url: playback.streamURL, headers: playback.headers)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        _ = try? await URLSession.shared.data(for: request)
    }

    private func effectiveHeadersForWarmup(url: URL, headers: [String: String]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return headers }
        if host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            return [:]
        }
        return headers
    }
}

private struct CachedResolvedPlayback {
    let playback: ResolvedPlayback
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

private struct PipedStreamsResponse: Decodable {
    let title: String?
    let description: String?
    let uploader: String?
    let uploaderURL: String?
    let hls: String?
    let videoStreams: [PipedVideoStream]

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case uploader
        case uploaderURL = "uploaderUrl"
        case hls
        case videoStreams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
        self.uploaderURL = try container.decodeIfPresent(String.self, forKey: .uploaderURL)
        self.hls = try container.decodeIfPresent(String.self, forKey: .hls)
        self.videoStreams = try container.decodeIfPresent([PipedVideoStream].self, forKey: .videoStreams) ?? []
    }
}

private struct PipedVideoStream: Decodable {
    let url: String
    let videoOnly: Bool
    let quality: String?
    let bitrate: Int
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case videoOnly
        case quality
        case bitrate
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.videoOnly = try container.decodeIfPresent(Bool.self, forKey: .videoOnly) ?? false
        self.quality = try container.decodeIfPresent(String.self, forKey: .quality)
        self.bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        self.width = try container.decodeIfPresent(Int.self, forKey: .width)
        self.height = try container.decodeIfPresent(Int.self, forKey: .height)
    }

    var qualityScore: Int {
        if let height { return height }
        guard let quality else { return 0 }
        let digits = quality.split { !$0.isNumber }
        return digits.first.flatMap { Int($0) } ?? 0
    }
}
