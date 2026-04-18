import SwiftUI
import AVKit

struct VideoPlaybackScreen: View {
    let videoId: String
    let initialTitle: String
    let initialMetaLine: String?
    let initialChannelName: String?
    let initialChannelAvatarURL: URL?
    let initialThumbnailURL: URL?
    let initialChannelId: String?

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: PlaybackSection = .description
    @StateObject private var details = VideoDetailsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(.black)

                    if let player = playback.player {
                        SystemPlayerView(player: player)
                    } else if playback.isLoading {
                        ProgressView("Загрузка видео...")
                            .tint(.white)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Не удалось загрузить поток")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.white)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VideoHeaderView(
                            title: playback.title ?? initialTitle,
                            metaLine: playback.metaLine ?? initialMetaLine,
                            channelName: playback.channelName ?? initialChannelName,
                            channelAvatarURL: playback.channelAvatarURL ?? initialChannelAvatarURL,
                            sourceLabel: playback.activeSourceLabel,
                            channelId: playback.channelId ?? initialChannelId,
                            isSubscribed: { channelId in
                                subscriptions.isSubscribed(channelId)
                            },
                            toggleSubscription: { channelId in
                                subscriptions.toggle(ChannelSubscription(
                                    id: channelId,
                                    title: playback.channelName ?? initialChannelName ?? "Канал",
                                    thumbnailURL: playback.channelAvatarURL ?? initialChannelAvatarURL
                                ))
                            },
                            errorMessage: playback.errorMessage
                        )

                        Divider()

                        PlaybackSectionContent(
                            selection: selectedSection,
                            descriptionText: playback.descriptionText,
                            details: details,
                            onSelectRelated: { item in
                                guard item.type == .video,
                                      let videoId = item.videoId else {
                                    return
                                }
                                Task {
                                    await playback.play(
                                        videoId: videoId,
                                        fallbackTitle: item.title,
                                        fallbackMetaLine: item.metaLine,
                                        fallbackChannelName: item.channelName,
                                        fallbackChannelAvatarURL: item.channelAvatarURL,
                                        fallbackThumbnailURL: item.thumbnailURL,
                                        fallbackChannelId: item.channelId
                                    )
                                    await details.loadRelated(
                                        for: playback.title ?? item.title,
                                        excluding: playback.currentVideoId
                                    )
                                    await details.loadComments(
                                        for: playback.currentVideoId,
                                        force: true
                                    )
                                }
                            }
                        )
                    }
                    .padding()
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) {
                PlaybackBottomBar(selection: $selectedSection)
            }
            .navigationTitle("Видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                await playback.play(
                    videoId: videoId,
                    fallbackTitle: initialTitle,
                    fallbackMetaLine: initialMetaLine,
                    fallbackChannelName: initialChannelName,
                    fallbackChannelAvatarURL: initialChannelAvatarURL,
                    fallbackThumbnailURL: initialThumbnailURL,
                    fallbackChannelId: initialChannelId
                )
                await details.loadRelated(
                    for: playback.title ?? initialTitle,
                    excluding: playback.currentVideoId
                )
                // Pre-warm comments in the background so they're ready the
                // moment the user taps the Comments tab. Safe to run even when
                // the user never visits the tab — the fetch costs one /next
                // round-trip and is cached per-videoId in the view-model.
                await details.loadComments(for: playback.currentVideoId ?? videoId)
            }
            .onChange(of: playback.title) { newTitle in
                guard let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                Task {
                    await details.loadRelated(
                        for: newTitle,
                        excluding: playback.currentVideoId
                    )
                }
            }
            .onChange(of: playback.currentVideoId) { newVideoId in
                // Video changed (e.g. user tapped a related card). Invalidate
                // and refetch comments for the new id.
                Task {
                    await details.loadComments(for: newVideoId, force: true)
                }
            }
            .onChange(of: selectedSection) { newSection in
                // Re-try if the user switches to Comments after a previous
                // failure (e.g. transient network error on first attempt).
                guard newSection == .comments else { return }
                if details.comments.isEmpty, !details.isLoadingComments {
                    Task {
                        await details.loadComments(
                            for: playback.currentVideoId ?? videoId,
                            force: true
                        )
                    }
                }
            }
        }
    }
}

private struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        // CRITICAL for the lock-screen Now Playing widget: AVPlayerViewController
        // defaults to overwriting MPNowPlayingInfoCenter.default().nowPlayingInfo
        // with minimal auto-generated metadata (no artwork, wrong command set).
        // That auto-overwrite is precisely what makes the widget render with
        // invisible transport icons — iOS draws the widget based on
        // AVPlayerViewController's skeletal info, ignoring our full setup in
        // PlaybackController. Turning this off lets our MPRemoteCommandCenter +
        // MPNowPlayingInfoCenter configuration own the widget end-to-end.
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

private enum PlaybackSection: String, CaseIterable, Identifiable {
    case description
    case comments
    case related

    var id: String { rawValue }

    var title: String {
        switch self {
        case .description: return "Описание"
        case .comments: return "Комментарии"
        case .related: return "Рекомендации"
        }
    }

    var systemImage: String {
        switch self {
        case .description: return "text.alignleft"
        case .comments: return "text.bubble"
        case .related: return "sparkles.tv"
        }
    }
}

@MainActor
private final class VideoDetailsViewModel: ObservableObject {
    @Published var related: [YouTubeSearchItem] = []
    @Published var isLoadingRelated = false
    @Published var relatedError: String?

    @Published var comments: [VideoComment] = []
    @Published var isLoadingComments = false
    @Published var commentsError: String?

    // Replies state, keyed by parent commentId. Persisted across the Comments
    // tab's lifetime so collapsing + re-expanding doesn't re-hit the network.
    @Published var repliesByParent: [String: [VideoComment]] = [:]
    @Published var expandedReplyParents: Set<String> = []
    @Published var loadingReplyParents: Set<String> = []
    @Published var repliesErrorByParent: [String: String] = [:]

    private let searchService: YouTubeSearchService
    private let commentsService: YouTubeCommentsService
    private var lastRelatedKey: String?
    private var lastCommentsVideoId: String?

    init(
        searchService: YouTubeSearchService = .shared,
        commentsService: YouTubeCommentsService = .shared
    ) {
        self.searchService = searchService
        self.commentsService = commentsService
    }

    func loadRelated(for query: String, excluding videoId: String?) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            related = []
            isLoadingRelated = false
            return
        }
        let key = "\(trimmed)|\(videoId ?? "")"
        guard lastRelatedKey != key else { return }
        lastRelatedKey = key

        isLoadingRelated = true
        relatedError = nil

        do {
            let page = try await searchService.search(query: trimmed, filter: .videos)
            related = page.items.filter { item in
                item.type == .video && item.videoId != videoId
            }
        } catch {
            related = []
            relatedError = error.localizedDescription
        }

        isLoadingRelated = false
    }

    /// Loads the top-ranked comments for `videoId`. Idempotent per-video so the
    /// user can flip between the Description/Comments/Related tabs without
    /// hammering the network.
    func loadComments(for videoId: String?, force: Bool = false) async {
        guard let videoId, !videoId.isEmpty else {
            comments = []
            lastCommentsVideoId = nil
            isLoadingComments = false
            commentsError = nil
            return
        }
        if !force, lastCommentsVideoId == videoId, !comments.isEmpty {
            return
        }
        if isLoadingComments, lastCommentsVideoId == videoId {
            return
        }

        lastCommentsVideoId = videoId
        isLoadingComments = true
        commentsError = nil
        // New video — purge any stale replies state so we don't render replies
        // that belong to the previously-viewed comment list.
        repliesByParent = [:]
        expandedReplyParents = []
        loadingReplyParents = []
        repliesErrorByParent = [:]

        do {
            let fetched = try await commentsService.fetchTopComments(videoId: videoId)
            // Guard against a stale response after the user jumps to a
            // different video while the request was in flight.
            guard lastCommentsVideoId == videoId else {
                isLoadingComments = false
                return
            }
            comments = fetched
            if fetched.isEmpty {
                commentsError = "Комментарии пока не найдены."
            }
        } catch {
            guard lastCommentsVideoId == videoId else {
                isLoadingComments = false
                return
            }
            comments = []
            commentsError = error.localizedDescription
        }

        isLoadingComments = false
    }

    /// Toggles the replies section for `comment`. First expansion fetches the
    /// replies; subsequent toggles are local-only (cached).
    func toggleReplies(for comment: VideoComment) async {
        let parentId = comment.id
        if expandedReplyParents.contains(parentId) {
            expandedReplyParents.remove(parentId)
            return
        }
        expandedReplyParents.insert(parentId)
        repliesErrorByParent[parentId] = nil

        // Already loaded — nothing more to do; just unhide.
        if repliesByParent[parentId] != nil { return }
        guard let token = comment.repliesContinuationToken else {
            repliesErrorByParent[parentId] = "Ответы недоступны."
            return
        }
        if loadingReplyParents.contains(parentId) { return }

        loadingReplyParents.insert(parentId)
        defer { loadingReplyParents.remove(parentId) }

        do {
            let replies = try await commentsService.fetchReplies(continuationToken: token)
            // Drop the result if the user collapsed the thread (or switched
            // videos) while the request was in flight.
            guard expandedReplyParents.contains(parentId) else { return }
            repliesByParent[parentId] = replies
            if replies.isEmpty {
                repliesErrorByParent[parentId] = "Ответов не найдено."
            }
        } catch {
            guard expandedReplyParents.contains(parentId) else { return }
            repliesErrorByParent[parentId] = error.localizedDescription
        }
    }
}

private struct VideoHeaderView: View {
    let title: String
    let metaLine: String?
    let channelName: String?
    let channelAvatarURL: URL?
    let sourceLabel: String?
    let channelId: String?
    let isSubscribed: (String) -> Bool
    let toggleSubscription: (String) -> Void
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.leading)

            if let meta = metaLine, !meta.isEmpty {
                Text(meta)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let sourceLabel, !sourceLabel.isEmpty {
                Text("Источник: \(sourceLabel)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                ChannelAvatarView(
                    avatarURL: channelAvatarURL,
                    fallbackText: String((channelName ?? "?").prefix(1))
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channelName ?? "Канал")
                        .font(.headline)
                    Text("Открыто из поиска")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if let channelId {
                    Button {
                        toggleSubscription(channelId)
                    } label: {
                        Text(isSubscribed(channelId) ? "Вы подписаны" : "Подписаться")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct PlaybackSectionContent: View {
    let selection: PlaybackSection
    let descriptionText: String?
    @ObservedObject var details: VideoDetailsViewModel
    let onSelectRelated: (YouTubeSearchItem) -> Void

    var body: some View {
        switch selection {
        case .description:
            DescriptionSection(text: descriptionText)
        case .comments:
            CommentsSection(details: details)
        case .related:
            RelatedSection(details: details, onSelect: onSelectRelated)
        }
    }
}

private struct DescriptionSection: View {
    let text: String?

    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SectionPlaceholderView(
                title: "Описание недоступно",
                systemImage: "text.alignleft",
                message: "У этого видео нет описания или оно пока не загружено."
            )
        }
    }
}

private struct CommentsSection: View {
    @ObservedObject var details: VideoDetailsViewModel

    var body: some View {
        if details.isLoadingComments && details.comments.isEmpty {
            ProgressView("Загрузка комментариев...")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else if details.comments.isEmpty, let error = details.commentsError {
            SectionPlaceholderView(
                title: "Комментариев нет",
                systemImage: "text.bubble",
                message: error
            )
        } else if details.comments.isEmpty {
            SectionPlaceholderView(
                title: "Комментариев нет",
                systemImage: "text.bubble",
                message: "Откройте вкладку «Комментарии», чтобы загрузить обсуждение."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(details.comments) { comment in
                    CommentThreadView(comment: comment, details: details)
                }
            }
        }
    }
}

private struct CommentThreadView: View {
    let comment: VideoComment
    @ObservedObject var details: VideoDetailsViewModel

    private var isExpanded: Bool {
        details.expandedReplyParents.contains(comment.id)
    }

    private var isLoadingReplies: Bool {
        details.loadingReplyParents.contains(comment.id)
    }

    private var loadedReplies: [VideoComment] {
        details.repliesByParent[comment.id] ?? []
    }

    private var replyError: String? {
        details.repliesErrorByParent[comment.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(comment: comment)

            if comment.replyCount > 0, comment.repliesContinuationToken != nil {
                Button {
                    Task { await details.toggleReplies(for: comment) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                        Text(isExpanded
                             ? "Скрыть ответы"
                             : "Показать ответы (\(comment.replyCount))")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.leading, 42)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingReplies && loadedReplies.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 6)
                    } else if loadedReplies.isEmpty, let replyError {
                        Text(replyError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loadedReplies) { reply in
                            CommentRow(comment: reply)
                        }
                    }
                }
                .padding(.leading, 42)
            }
        }
    }
}

private struct RelatedSection: View {
    @ObservedObject var details: VideoDetailsViewModel
    let onSelect: (YouTubeSearchItem) -> Void

    var body: some View {
        if details.isLoadingRelated {
            ProgressView("Подбираем рекомендации...")
        } else if let error = details.relatedError {
            SectionPlaceholderView(
                title: "Не удалось загрузить",
                systemImage: "exclamationmark.triangle",
                message: error
            )
        } else if details.related.isEmpty {
            SectionPlaceholderView(
                title: "Нет рекомендаций",
                systemImage: "sparkles.tv",
                message: "Попробуйте обновить или выберите другое видео."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(details.related) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        RelatedVideoRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PlaybackBottomBar: View {
    @Binding var selection: PlaybackSection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PlaybackSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(section.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(selection == section ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }
}

private struct RelatedVideoRow: View {
    let item: YouTubeSearchItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnailURL = item.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.gray.opacity(0.2))
                            .overlay(ProgressView())
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.gray.opacity(0.2))
                        .overlay {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let channel = item.channelName {
                    Text(channel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let meta = item.metaLine, !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: VideoComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChannelAvatarView(
                avatarURL: comment.authorThumbnailURL,
                fallbackText: String(comment.author.prefix(1))
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if comment.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(comment.isChannelOwner ? .orange : .primary)
                    if comment.isChannelOwner {
                        Text("Автор")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if let published = comment.publishedText, !published.isEmpty {
                        Text(published)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(comment.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 16) {
                    if let likes = comment.likeCountText, !likes.isEmpty {
                        Label(likes, systemImage: "hand.thumbsup")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if comment.replyCount > 0 {
                        Label("\(comment.replyCount)", systemImage: "bubble.left")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SectionPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }
}

private struct ChannelAvatarView: View {
    let avatarURL: URL?
    let fallbackText: String

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.gray.opacity(0.2))
                }
            } else {
                Circle()
                    .fill(.orange.opacity(0.2))
                    .overlay {
                        Text(fallbackText)
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .clipShape(Circle())
    }
}
