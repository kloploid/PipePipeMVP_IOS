import Foundation

/// Public model surfaced to the UI. Mirrors the fields exposed by
/// NewPipeExtractor's `CommentsInfoItem`, trimmed to what the read-only
/// MVP cares about (no replies thread, no vote action).
struct VideoComment: Identifiable, Equatable {
    let id: String
    let author: String
    let authorThumbnailURL: URL?
    let text: String
    let likeCountText: String?
    let publishedText: String?
    let replyCount: Int
    let isPinned: Bool
    let isChannelOwner: Bool
    /// Opaque InnerTube token to fetch this comment's replies via
    /// `YouTubeCommentsService.fetchReplies(continuationToken:)`. `nil` for
    /// reply entries themselves (YouTube doesn't nest beyond one level) and
    /// for top-level comments without a visible replies thread.
    let repliesContinuationToken: String?
}

/// Fetches the comment thread for a video via InnerTube `/next`.
///
/// Flow (matches NewPipeExtractor's `YoutubeCommentsExtractor`):
///   1. POST `/next` with `{videoId}` → response has engagementPanels and a
///      `continuationItemRenderer` whose `continuationCommand.token`
///      identifies the comments feed.
///   2. POST `/next` with `{continuation: <token>}` → either legacy
///      `commentThreadRenderer.comment.commentRenderer` entries or the new
///      `commentViewModel` that references entity keys materialised in
///      `frameworkUpdates.entityBatchUpdate.mutations[].commentEntityPayload`.
///
/// Both encodings are parsed here; YouTube has been rolling out the entity
/// payload form gradually since mid-2024.
actor YouTubeCommentsService {
    static let shared = YouTubeCommentsService()

    private let session: URLSession
    private let search: YouTubeSearchService

    init(session: URLSession = .shared, search: YouTubeSearchService = .shared) {
        self.session = session
        self.search = search
    }

    enum CommentsError: LocalizedError {
        case badURL
        case httpStatus(Int)
        case invalidJSON
        case disabled

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Не удалось сформировать URL комментариев."
            case .httpStatus(let code):
                return "Ошибка YouTube: HTTP \(code)."
            case .invalidJSON:
                return "Ответ YouTube не удалось прочитать."
            case .disabled:
                return "Комментарии к этому видео отключены."
            }
        }
    }

    /// Returns up to `limit` top-ranked comments. Throws
    /// `CommentsError.disabled` when the video has no `continuationItemRenderer`
    /// for the comments panel (usually means comments are off).
    func fetchTopComments(videoId: String, limit: Int = 20) async throws -> [VideoComment] {
        let (apiKey, clientVersion) = await search.innertubeAccess()
        let context = await search.innertubeContext()

        // Step 1: resolve comments continuation token.
        let firstRoot = try await postNext(
            apiKey: apiKey,
            clientVersion: clientVersion,
            body: [
                "context": context,
                "videoId": videoId
            ]
        )

        guard let continuationToken = findCommentsContinuationToken(root: firstRoot) else {
            throw CommentsError.disabled
        }

        // Step 2: fetch first page of comments.
        let commentsRoot = try await postNext(
            apiKey: apiKey,
            clientVersion: clientVersion,
            body: [
                "context": context,
                "continuation": continuationToken
            ]
        )

        let comments = parseComments(root: commentsRoot)
        return Array(comments.prefix(limit))
    }

    /// Loads a comment's replies using the `repliesContinuationToken` surfaced
    /// on a parent `VideoComment`. Replies come back as flat
    /// `{commentViewModel}` items (no nested `commentThreadRenderer` wrapper)
    /// and don't carry their own `replies` subtree — YouTube only threads one
    /// level deep, so the returned comments always have
    /// `repliesContinuationToken == nil`.
    func fetchReplies(continuationToken: String, limit: Int = 100) async throws -> [VideoComment] {
        let (apiKey, clientVersion) = await search.innertubeAccess()
        let context = await search.innertubeContext()

        let root = try await postNext(
            apiKey: apiKey,
            clientVersion: clientVersion,
            body: [
                "context": context,
                "continuation": continuationToken
            ]
        )

        let replies = parseComments(root: root)
        return Array(replies.prefix(limit))
    }

    // MARK: - Networking

    private func postNext(
        apiKey: String,
        clientVersion: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/next")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        guard let url = components.url else { throw CommentsError.badURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommentsError.httpStatus(-1)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CommentsError.httpStatus(httpResponse.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommentsError.invalidJSON
        }
        return object
    }

    // MARK: - Continuation-token discovery

    private func findCommentsContinuationToken(root: [String: Any]) -> String? {
        // Preferred: engagementPanels[panelIdentifier contains "comments"].
        if let panels = root["engagementPanels"] as? [[String: Any]] {
            for panel in panels {
                guard let panelRenderer = panel["engagementPanelSectionListRenderer"] as? [String: Any]
                else { continue }
                let identifier = (panelRenderer["panelIdentifier"] as? String) ?? ""
                let targetId = (panelRenderer["targetId"] as? String) ?? ""
                guard identifier.contains("comments") || targetId.contains("comments") else { continue }
                if let token = deepContinuationToken(in: panel) {
                    return token
                }
            }
        }

        // Fallback: any engagement panel continuation (older responses).
        if let panels = root["engagementPanels"] {
            if let token = deepContinuationToken(in: panels) { return token }
        }

        // Last resort: anywhere in the response.
        return deepContinuationToken(in: root)
    }

    private func deepContinuationToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let renderer = dict["continuationItemRenderer"] as? [String: Any],
               let endpoint = renderer["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String,
               !token.isEmpty {
                return token
            }
            for child in dict.values {
                if let token = deepContinuationToken(in: child) {
                    return token
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let token = deepContinuationToken(in: child) {
                    return token
                }
            }
        }
        return nil
    }

    // MARK: - Comment parsing

    private func parseComments(root: [String: Any]) -> [VideoComment] {
        let entityLookup = buildCommentEntityLookup(root: root)
        let continuationItems = extractContinuationItems(root: root)

        var collected: [VideoComment] = []
        for item in continuationItems {
            // Case A — thread item (top-level list): `commentThreadRenderer`
            // wraps the viewModel and a `replies` subtree that carries the
            // token we need to fetch this thread's replies.
            if let thread = item["commentThreadRenderer"] as? [String: Any] {
                let repliesToken = deepContinuationToken(in: thread["replies"] ?? [:])

                if let viewModelContainer = thread["commentViewModel"] as? [String: Any],
                   let viewModel = viewModelContainer["commentViewModel"] as? [String: Any],
                   let commentKey = viewModel["commentKey"] as? String,
                   let entity = entityLookup[commentKey],
                   let parsed = parseEntityComment(
                       entity,
                       toolbarKey: viewModel["toolbarStateKey"] as? String,
                       toolbarLookup: entityLookup,
                       repliesContinuationToken: repliesToken
                   ) {
                    collected.append(parsed)
                    continue
                }

                if let commentRenderer = (thread["comment"] as? [String: Any])?["commentRenderer"] as? [String: Any],
                   let parsed = parseLegacyComment(
                       renderer: commentRenderer,
                       thread: thread,
                       repliesContinuationToken: repliesToken
                   ) {
                    collected.append(parsed)
                    continue
                }
            }

            // Case B — reply item: replies come back flat as `{commentViewModel: {...}}`
            // with no outer `commentThreadRenderer` and no nested viewModel.
            if let viewModel = item["commentViewModel"] as? [String: Any],
               let commentKey = viewModel["commentKey"] as? String,
               let entity = entityLookup[commentKey],
               let parsed = parseEntityComment(
                   entity,
                   toolbarKey: viewModel["toolbarStateKey"] as? String,
                   toolbarLookup: entityLookup,
                   repliesContinuationToken: nil
               ) {
                collected.append(parsed)
                continue
            }
        }
        return collected
    }

    private func extractContinuationItems(root: [String: Any]) -> [[String: Any]] {
        guard let endpoints = root["onResponseReceivedEndpoints"] as? [[String: Any]] else {
            return []
        }
        // YouTube splits the comments feed across multiple endpoints: the first
        // reloadContinuationItemsCommand typically wraps only commentsHeaderRenderer
        // (sort menu, count), while a second one carries the actual commentThreadRenderer
        // entries. Flatten all of them so parsing sees every thread, not just the header.
        var collected: [[String: Any]] = []
        for endpoint in endpoints {
            if let reload = endpoint["reloadContinuationItemsCommand"] as? [String: Any],
               let items = reload["continuationItems"] as? [[String: Any]] {
                collected.append(contentsOf: items)
            }
            if let append = endpoint["appendContinuationItemsAction"] as? [String: Any],
               let items = append["continuationItems"] as? [[String: Any]] {
                collected.append(contentsOf: items)
            }
        }
        return collected
    }

    /// Flattens `frameworkUpdates.entityBatchUpdate.mutations[]` into a
    /// `key → payload` map. Handles both `commentEntityPayload` (the comment
    /// body) and `engagementToolbarStateEntityPayload` (like counts).
    private func buildCommentEntityLookup(root: [String: Any]) -> [String: [String: Any]] {
        var lookup: [String: [String: Any]] = [:]
        guard let framework = root["frameworkUpdates"] as? [String: Any],
              let batch = framework["entityBatchUpdate"] as? [String: Any],
              let mutations = batch["mutations"] as? [[String: Any]] else {
            return lookup
        }
        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any] else { continue }
            if let commentEntity = payload["commentEntityPayload"] as? [String: Any],
               let key = commentEntity["key"] as? String {
                lookup[key] = commentEntity
            }
            if let toolbarEntity = payload["engagementToolbarStateEntityPayload"] as? [String: Any],
               let key = toolbarEntity["key"] as? String {
                lookup[key] = toolbarEntity
            }
        }
        return lookup
    }

    private func parseEntityComment(
        _ entity: [String: Any],
        toolbarKey: String?,
        toolbarLookup: [String: [String: Any]],
        repliesContinuationToken: String?
    ) -> VideoComment? {
        let properties = entity["properties"] as? [String: Any]
        let author = entity["author"] as? [String: Any]
        let toolbar = entity["toolbar"] as? [String: Any]
        let avatar = entity["avatar"] as? [String: Any]

        let contentBlock = properties?["content"] as? [String: Any]
        let text = (contentBlock?["content"] as? String) ?? ""
        guard !text.isEmpty else { return nil }

        let commentId = (properties?["commentId"] as? String) ?? UUID().uuidString
        let publishedText = properties?["publishedTime"] as? String

        let displayName = (author?["displayName"] as? String) ?? "YouTube"
        let isCreator = (author?["isCreator"] as? Bool) ?? false

        let avatarURL: URL? = {
            let candidates: [[String: Any]?] = [
                avatar,
                author?["avatar"] as? [String: Any]
            ]
            for candidate in candidates {
                guard let container = candidate else { continue }
                if let image = container["image"] as? [String: Any],
                   let sources = image["sources"] as? [[String: Any]],
                   let urlString = (sources.last?["url"] as? String) ?? (sources.first?["url"] as? String) {
                    return URL(string: urlString)
                }
                if let sources = container["sources"] as? [[String: Any]],
                   let urlString = (sources.last?["url"] as? String) ?? (sources.first?["url"] as? String) {
                    return URL(string: urlString)
                }
            }
            return nil
        }()

        let likeCountText: String? = {
            if let value = toolbar?["likeCountNotliked"] as? String, !value.isEmpty { return value }
            if let value = toolbar?["likeCountLiked"] as? String, !value.isEmpty { return value }
            if let value = toolbar?["likeCountA11y"] as? String, !value.isEmpty { return value }
            if let key = toolbarKey,
               let toolbarEntity = toolbarLookup[key],
               let value = toolbarEntity["likeCountA11y"] as? String, !value.isEmpty {
                return value
            }
            return nil
        }()

        let replyCount: Int = {
            if let value = toolbar?["replyCount"] as? Int {
                return value
            }
            if let value = toolbar?["replyCount"] as? String,
               let parsed = Int(value) {
                return parsed
            }
            return 0
        }()

        let isPinned: Bool = {
            if let pinned = properties?["pinnedText"] as? String, !pinned.isEmpty { return true }
            return false
        }()

        return VideoComment(
            id: commentId,
            author: displayName,
            authorThumbnailURL: avatarURL,
            text: text,
            likeCountText: likeCountText,
            publishedText: publishedText,
            replyCount: replyCount,
            isPinned: isPinned,
            isChannelOwner: isCreator,
            repliesContinuationToken: repliesContinuationToken
        )
    }

    private func parseLegacyComment(
        renderer: [String: Any],
        thread: [String: Any],
        repliesContinuationToken: String?
    ) -> VideoComment? {
        let text = runsText(renderer["contentText"]) ?? simpleText(renderer["contentText"]) ?? ""
        guard !text.isEmpty else { return nil }

        let id = (renderer["commentId"] as? String) ?? UUID().uuidString
        let author = runsText(renderer["authorText"]) ?? simpleText(renderer["authorText"]) ?? "YouTube"
        let published = runsText(renderer["publishedTimeText"]) ?? simpleText(renderer["publishedTimeText"])

        let likeCountText: String? = {
            if let value = renderer["voteCount"] {
                return simpleText(value) ?? runsText(value)
            }
            if let value = renderer["likeCount"] as? String, !value.isEmpty {
                return value
            }
            return nil
        }()

        let avatarURL: URL? = {
            guard let image = renderer["authorThumbnail"] as? [String: Any],
                  let thumbnails = image["thumbnails"] as? [[String: Any]],
                  let urlString = (thumbnails.last?["url"] as? String) ?? (thumbnails.first?["url"] as? String) else {
                return nil
            }
            return URL(string: urlString)
        }()

        let replyCount: Int = {
            guard let replies = thread["replies"] as? [String: Any],
                  let rendererReplies = replies["commentRepliesRenderer"] as? [String: Any],
                  let moreText = rendererReplies["moreText"] as? [String: Any] else {
                return 0
            }
            let flat = runsText(moreText) ?? simpleText(moreText) ?? ""
            let digits = flat.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            return Int(digits) ?? 0
        }()

        let isPinned = renderer["pinnedCommentBadge"] != nil
        let isChannelOwner = (renderer["authorIsChannelOwner"] as? Bool) ?? false

        return VideoComment(
            id: id,
            author: author,
            authorThumbnailURL: avatarURL,
            text: text,
            likeCountText: likeCountText,
            publishedText: published,
            replyCount: replyCount,
            isPinned: isPinned,
            isChannelOwner: isChannelOwner,
            repliesContinuationToken: repliesContinuationToken
        )
    }

    private func simpleText(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return dict["simpleText"] as? String
    }

    private func runsText(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
}
