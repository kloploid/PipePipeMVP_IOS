import Foundation
import SwiftUI
import WebKit

struct VideoPlayerScreen: View {
    let initialVideoID: String

    @State private var useEmbeddedFallback = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var actionMessage: String?
    @State private var isActionAlertPresented = false
    @State private var isAddToPlaylistPresented = false
    @State private var newPlaylistName = ""
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let service: VideoSearchServicing = VideoSearchService()

    private var currentItem: VideoItem {
        queueViewModel.currentItem ?? VideoItem(
            id: initialVideoID,
            title: "YouTube video \(initialVideoID)",
            channelTitle: "YouTube",
            channelID: nil,
            thumbnailURL: nil,
            durationText: nil,
            publishedText: nil,
            isLive: false
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if queueViewModel.hasActiveMedia {
                    ZStack(alignment: .bottom) {
                        KSVideoSurfaceView()
                            .environmentObject(queueViewModel)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        PlayerOverlayControls(
                            isPlaying: queueViewModel.isPlaying,
                            currentTime: isScrubbing ? scrubPosition : queueViewModel.playbackTick,
                            duration: queueViewModel.durationSeconds,
                            onTogglePlayPause: { queueViewModel.togglePlayPause() },
                            onSeekBackward: { queueViewModel.seekBy(-10) },
                            onSeekForward: { queueViewModel.seekBy(10) },
                            onSliderChanged: { value in
                                isScrubbing = true
                                scrubPosition = value
                            },
                            onSliderCommit: {
                                queueViewModel.seek(to: scrubPosition)
                                isScrubbing = false
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                } else if useEmbeddedFallback, let url = currentItem.embedURL {
                    YouTubePlayerWebView(embedURL: url)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                } else if queueViewModel.isLoadingStream {
                    ProgressView("Loading stream...")
                        .frame(height: 240)
                } else {
                    VStack(spacing: 8) {
                        Text(queueViewModel.streamError ?? "Video unavailable")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if currentItem.embedURL != nil {
                            Button("Open embedded fallback") {
                                useEmbeddedFallback = true
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Retry stream") {
                            queueViewModel.retryCurrent()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(currentItem.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(currentItem.channelTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ShareLink(item: currentItem.embedURL ?? URL(string: "https://www.youtube.com/watch?v=\(currentItem.id)")!) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        Button("Open") {
                            if let url = URL(string: "https://www.youtube.com/watch?v=\(currentItem.id)") {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Add to playlist") {
                            isAddToPlaylistPresented = true
                        }
                        .buttonStyle(.bordered)

                        Button("Download") {
                            Task { await downloadCurrentVideo() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)

                if queueViewModel.isSponsorBlockEnabled() {
                    let duration = queueViewModel.durationSeconds
                    if duration.isFinite, duration > 0 {
                        SponsorTimelineView(
                            segments: queueViewModel.sponsorSegments,
                            duration: duration
                        )
                        .padding(.horizontal)
                    }

                    Text(queueViewModel.sponsorSegments.isEmpty
                        ? "SponsorBlock enabled (no segments for this video)"
                        : "SponsorBlock enabled (\(queueViewModel.sponsorSegments.count) segments)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                if let channelID = currentItem.channelID {
                    HStack {
                        if libraryViewModel.isSubscribed(channelId: channelID) {
                            Button("Unsubscribe") {
                                libraryViewModel.unsubscribe(channelId: channelID)
                                actionMessage = "Removed subscription"
                                isActionAlertPresented = true
                            }
                        } else {
                            Button("Subscribe") {
                                libraryViewModel.subscribe(
                                    channelId: channelID,
                                    channelName: currentItem.channelTitle
                                )
                                actionMessage = "Subscribed to \(currentItem.channelTitle)"
                                isActionAlertPresented = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button("Previous") {
                        queueViewModel.previous()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!queueViewModel.hasPrevious)

                    Button("Next") {
                        queueViewModel.next()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!queueViewModel.hasNext)
                }
                .padding(.horizontal)

                if !queueViewModel.queue.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Queue")
                            .font(.headline)
                            .padding(.horizontal)

                        LazyVStack(spacing: 8) {
                            ForEach(Array(queueViewModel.queue.enumerated()), id: \.offset) { index, item in
                                Button {
                                    queueViewModel.jumpTo(index: index)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .lineLimit(1)
                                            Text(item.channelTitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if queueViewModel.currentIndex == index {
                                            Text("Now")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            queueViewModel.ensureCurrent(videoId: initialVideoID)
        }
        .onAppear {
            libraryViewModel.addToHistory(currentItem)
            scrubPosition = queueViewModel.playbackTick
        }
        .onChange(of: currentItem.id) { _ in
            libraryViewModel.addToHistory(currentItem)
            isScrubbing = false
            scrubPosition = 0
        }
        .onChange(of: queueViewModel.playbackTick) { value in
            if !isScrubbing {
                scrubPosition = value
            }
        }
        .alert("Action", isPresented: $isActionAlertPresented, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(actionMessage ?? "")
        })
        .sheet(isPresented: $isAddToPlaylistPresented) {
            NavigationStack {
                List {
                    Section("Existing playlists") {
                        if libraryViewModel.playlists.isEmpty {
                            Text("No playlists. Create one below.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(libraryViewModel.playlists) { playlist in
                                Button(playlist.name) {
                                    libraryViewModel.add(currentItem, to: playlist.id)
                                    actionMessage = "Added to \(playlist.name)"
                                    isActionAlertPresented = true
                                    isAddToPlaylistPresented = false
                                }
                            }
                        }
                    }
                    Section("Create new playlist") {
                        TextField("Playlist name", text: $newPlaylistName)
                        Button("Create and add") {
                            let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            libraryViewModel.createPlaylist(name: trimmed)
                            if let created = libraryViewModel.playlists.last {
                                libraryViewModel.add(currentItem, to: created.id)
                            }
                            actionMessage = "Playlist created"
                            isActionAlertPresented = true
                            isAddToPlaylistPresented = false
                            newPlaylistName = ""
                        }
                    }
                }
                .navigationTitle("Add to playlist")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") {
                            isAddToPlaylistPresented = false
                        }
                    }
                }
            }
        }
    }

    private func downloadCurrentVideo() async {
        do {
            let source = try await resolveDownloadSource()
            if source.isHLS {
                actionMessage = "HLS manifest download is not supported in MVP yet."
                isActionAlertPresented = true
                return
            }

            let (tmpURL, _) = try await URLSession.shared.download(from: source.url)
            let destination = makeDownloadDestinationURL(for: currentItem)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmpURL, to: destination)

            actionMessage = "Saved to Files: \(destination.lastPathComponent)"
            isActionAlertPresented = true
        } catch {
            actionMessage = "Download failed: \(error.localizedDescription)"
            isActionAlertPresented = true
        }
    }

    private func resolveDownloadSource() async throws -> PlaybackSource {
        try await service.resolvePlayback(videoId: currentItem.id)
    }

    private func makeDownloadDestinationURL(for item: VideoItem) -> URL {
        let base = item.title
            .replacingOccurrences(of: "[^A-Za-z0-9_\\- ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (base.isEmpty ? item.id : base) + ".mp4"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(fileName)
    }
}

private struct PlayerOverlayControls: View {
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let onTogglePlayPause: () -> Void
    let onSeekBackward: () -> Void
    let onSeekForward: () -> Void
    let onSliderChanged: (Double) -> Void
    let onSliderCommit: () -> Void

    private var clampedCurrentTime: Double {
        max(0, min(durationValue, currentTime.isFinite ? currentTime : 0))
    }

    private var durationValue: Double {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return max(1, currentTime + 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 28) {
                Button(action: onSeekBackward) {
                    Image(systemName: "gobackward.10")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44, weight: .regular))
                }
                .buttonStyle(.plain)

                Button(action: onSeekForward) {
                    Image(systemName: "goforward.10")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)

            Slider(
                value: Binding(
                    get: { clampedCurrentTime },
                    set: { onSliderChanged($0) }
                ),
                in: 0...durationValue,
                onEditingChanged: { editing in
                    if !editing {
                        onSliderCommit()
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(formatTime(clampedCurrentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct SponsorTimelineView: View {
    let segments: [SponsorSegment]
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: 6)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let startRatio = max(0, min(1, segment.start / duration))
                    let endRatio = max(0, min(1, segment.end / duration))
                    let width = max(2, (endRatio - startRatio) * geo.size.width)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: width, height: 6)
                        .offset(x: startRatio * geo.size.width)
                }
            }
        }
        .frame(height: 6)
    }
}

private struct YouTubePlayerWebView: UIViewRepresentable {
    let embedURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        return WKWebView(frame: .zero, configuration: config)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!doctype html>
        <html>
        <body style="margin:0;background:#000;">
          <iframe
            width="100%"
            height="100%"
            src="\(embedURL.absoluteString)&autoplay=1"
            frameborder="0"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
            allowfullscreen>
          </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }
}
