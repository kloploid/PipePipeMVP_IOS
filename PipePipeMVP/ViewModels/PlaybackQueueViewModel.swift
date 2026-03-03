import Foundation
import AVFoundation
import SwiftUI
import MediaPlayer
import UIKit
import KSPlayer

@MainActor
final class PlaybackQueueViewModel: ObservableObject {
    @Published private(set) var queue: [VideoItem] = []
    @Published private(set) var currentIndex: Int?
    @Published var isPlayerPresented = false
    @Published private(set) var isLoadingStream = false
    @Published private(set) var streamError: String?
    @Published private(set) var sponsorSegments: [SponsorSegment] = []
    @Published private(set) var playbackTick: Double = 0

    private let service: VideoSearchServicing
    private let sponsorBlockService: SponsorBlockServicing
    private var playerLayer: KSPlayerLayer?
    private weak var playerContainer: UIView?
    private var loadTask: Task<Void, Never>?
    private var remoteCommandsConfigured = false
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var lastSkippedSegmentEnd: Double = -1
    private var tickTimer: Timer?

    var currentItem: VideoItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var hasActiveMedia: Bool {
        playerLayer != nil
    }

    var isPlaying: Bool {
        playerLayer?.player.isPlaying ?? false
    }

    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < queue.count
    }

    var hasPrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    var currentTimeSeconds: Double {
        playerLayer?.player.currentPlaybackTime ?? 0
    }

    var durationSeconds: Double {
        playerLayer?.player.duration ?? 0
    }

    init(
        service: VideoSearchServicing = VideoSearchService(),
        sponsorBlockService: SponsorBlockServicing = SponsorBlockService()
    ) {
        self.service = service
        self.sponsorBlockService = sponsorBlockService
        KSOptions.isAutoPlay = false
        configureAudioSession()
        configureRemoteCommands()
        startTickTimer()
    }

    deinit {
        tickTimer?.invalidate()
    }

    func attachPlayerContainer(_ view: UIView) {
        playerContainer = view
        attachPlayerViewIfNeeded()
    }

    func startPlayback(with videos: [VideoItem], at index: Int) {
        guard videos.indices.contains(index) else { return }
        queue = videos
        setCurrentIndex(index, autoPlay: true)
        isPlayerPresented = true
    }

    func playNow(_ video: VideoItem) {
        queue = [video]
        setCurrentIndex(0, autoPlay: true)
        isPlayerPresented = true
    }

    func ensureCurrent(videoId: String) {
        if let idx = queue.firstIndex(where: { $0.id == videoId }) {
            if currentIndex != idx {
                setCurrentIndex(idx, autoPlay: true)
            }
            return
        }

        let placeholder = VideoItem(
            id: videoId,
            title: "YouTube video \(videoId)",
            channelTitle: "YouTube",
            channelID: nil,
            thumbnailURL: nil,
            durationText: nil,
            publishedText: nil,
            isLive: false
        )
        queue = [placeholder]
        setCurrentIndex(0, autoPlay: true)
    }

    func enqueue(_ video: VideoItem) {
        queue.append(video)
        if currentIndex == nil {
            currentIndex = 0
        }
    }

    func playNext(_ video: VideoItem) {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            enqueue(video)
            return
        }
        queue.insert(video, at: currentIndex + 1)
    }

    func next() {
        guard hasNext, let currentIndex else { return }
        setCurrentIndex(currentIndex + 1, autoPlay: true)
    }

    func previous() {
        guard hasPrevious, let currentIndex else { return }
        setCurrentIndex(currentIndex - 1, autoPlay: true)
    }

    func jumpTo(index: Int) {
        setCurrentIndex(index, autoPlay: true)
    }

    func presentPlayer() {
        guard currentItem != nil else { return }
        isPlayerPresented = true
    }

    func retryCurrent() {
        guard currentItem != nil else { return }
        loadCurrent(autoPlay: true)
    }

    func togglePlayPause() {
        if isPlaying {
            playerLayer?.pause()
        } else {
            playerLayer?.play()
        }
        updateNowPlayingInfo()
        objectWillChange.send()
    }

    func seek(to seconds: Double) {
        guard hasActiveMedia, seconds.isFinite else { return }
        let duration = durationSeconds
        let bounded: Double
        if duration.isFinite, duration > 0 {
            bounded = min(max(0, seconds), duration)
        } else {
            bounded = max(0, seconds)
        }
        playerLayer?.seek(time: bounded, autoPlay: isPlaying) { _ in }
        playbackTick = bounded
        updateNowPlayingInfo()
    }

    func seekBy(_ deltaSeconds: Double) {
        seek(to: currentTimeSeconds + deltaSeconds)
    }

    private func setCurrentIndex(_ index: Int, autoPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        if currentIndex == index, hasActiveMedia {
            if autoPlay, !isPlaying {
                playerLayer?.play()
            }
            return
        }
        currentIndex = index
        loadCurrent(autoPlay: autoPlay)
    }

    private func loadCurrent(autoPlay: Bool) {
        guard let item = currentItem else { return }

        loadTask?.cancel()
        sponsorSegments = []
        lastSkippedSegmentEnd = -1
        loadTask = Task { [weak self] in
            guard let self else { return }
            self.isLoadingStream = true
            self.streamError = nil
            do {
                let source = try await self.service.resolvePlayback(videoId: item.id)
                if Task.isCancelled { return }

                let options = KSOptions()
                options.registerRemoteControll = true
                self.playerLayer?.pause()
                self.playerLayer = KSPlayerLayer(url: source.url, options: options)

                self.attachPlayerViewIfNeeded()
                self.isLoadingStream = false
                self.updateNowPlayingInfo()
                await self.loadArtwork(for: item)
                await self.loadSponsorSegments(for: item.id)
                if autoPlay {
                    self.playerLayer?.play()
                    self.updateNowPlayingInfo()
                }
            } catch {
                if Task.isCancelled { return }
                self.streamError = error.localizedDescription
                self.isLoadingStream = false
            }
        }
    }

    private func attachPlayerViewIfNeeded() {
        guard let container = playerContainer,
              let playerView = playerLayer?.player.view else { return }

        if playerView.superview !== container {
            playerView.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                playerView.topAnchor.constraint(equalTo: container.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch { }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active || phase == .background else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { }
        updateNowPlayingInfo()
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playerLayer?.play()
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.playerLayer?.pause()
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.next()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.previous()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.playerLayer?.seek(time: event.positionTime, autoPlay: self.isPlaying) { _ in }
            self.updateNowPlayingInfo()
            return .success
        }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.playbackTick = self.currentTimeSeconds
            self.updateNowPlayingInfo()
            self.handleSponsorBlockTick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func updateNowPlayingInfo() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channelTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, currentTimeSeconds)
        ]

        if durationSeconds.isFinite, durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }

        if let artwork = artworkCache[item.id] {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for item: VideoItem) async {
        guard artworkCache[item.id] == nil, let url = item.thumbnailURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache[item.id] = artwork
                updateNowPlayingInfo()
            }
        } catch { }
    }

    private func loadSponsorSegments(for videoID: String) async {
        if !isSponsorBlockEnabled() {
            sponsorSegments = []
            return
        }
        do {
            sponsorSegments = try await sponsorBlockService.fetchSegments(videoID: videoID)
        } catch {
            sponsorSegments = []
        }
    }

    private func handleSponsorBlockTick() {
        guard isSponsorBlockEnabled(), !sponsorSegments.isEmpty else { return }
        let currentTime = currentTimeSeconds
        guard currentTime.isFinite, currentTime >= 0 else { return }

        for segment in sponsorSegments {
            if currentTime >= segment.start && currentTime < segment.end {
                if abs(lastSkippedSegmentEnd - segment.end) < 0.3 {
                    return
                }
                lastSkippedSegmentEnd = segment.end
                playerLayer?.seek(time: segment.end + 0.05, autoPlay: true) { _ in }
                break
            }
        }
    }

    func isSponsorBlockEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "setting_sponsorblock_enabled") == nil {
            return true
        }
        return defaults.bool(forKey: "setting_sponsorblock_enabled")
    }
}
