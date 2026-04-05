import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import AVKit
import UIKit

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var title: String?
    @Published var metaLine: String?
    @Published var channelName: String?
    @Published var channelAvatarURL: URL?
    @Published var channelId: String?
    @Published var thumbnailURL: URL?
    @Published var descriptionText: String?
    @Published var currentVideoId: String?
    @Published var presentation: Presentation?
    @Published var isPlayingState: Bool = false
    @Published var activeSourceLabel: String?

    struct Presentation: Identifiable {
        let id: String
        let videoId: String
        let title: String
        let metaLine: String?
        let channelName: String?
        let channelAvatarURL: URL?
        let thumbnailURL: URL?
        let channelId: String?
    }

    var isPlaying: Bool {
        isPlayingState
    }

    var hasActivePlayback: Bool {
        player != nil
    }

    private let playbackService = YouTubePlaybackService.shared
    private let resolver: PlaybackResolver
    private let settings: AppSettingsStore
    private var playerStatusObservation: NSKeyValueObservation?
    private var remoteCommandsConfigured = false
    private var tickTimer: Timer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var hlsProxy: HLSProxy?
    private var isDeviceLocked = false
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var currentArtwork: MPMediaItemArtwork?
    private var currentPlayerId: String?
    private var attemptedPipedRecoveryForVideoId: String?
    private var isRecoveringViaPiped = false
    private let pipedAutoFallbackEnabled = false

    init(
        resolver: PlaybackResolver = .shared,
        settings: AppSettingsStore = .shared
    ) {
        self.resolver = resolver
        self.settings = settings
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        startTickTimer()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(notification)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDeviceLock()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDeviceLocked = false
            }
        }
    }

    deinit {
        tickTimer?.invalidate()
    }

    func play(
        videoId: String,
        fallbackTitle: String,
        fallbackMetaLine: String?,
        fallbackChannelName: String?,
        fallbackChannelAvatarURL: URL?,
        fallbackThumbnailURL: URL?,
        fallbackChannelId: String?
    ) async {
        if currentVideoId == videoId, player != nil, errorMessage == nil {
            return
        }

        isLoading = true
        errorMessage = nil
        currentVideoId = videoId
        title = fallbackTitle
        metaLine = fallbackMetaLine
        channelName = fallbackChannelName
        channelAvatarURL = fallbackChannelAvatarURL
        thumbnailURL = fallbackThumbnailURL
        channelId = fallbackChannelId
        descriptionText = nil
        currentPlayerId = nil
        activeSourceLabel = nil
        attemptedPipedRecoveryForVideoId = nil
        isRecoveringViaPiped = false

        do {
            let playback = try await resolver.resolve(
                videoId: videoId,
                mode: settings.playbackSourceMode
            )
            title = playback.title ?? fallbackTitle
            channelName = playback.channelName ?? fallbackChannelName
            channelId = playback.channelId ?? fallbackChannelId
            descriptionText = playback.description
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            Task {
                await self.probeStream(url: playback.streamURL, headers: playback.headers)
            }
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            ensureAudioSessionActive()
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            updateNowPlayingInfo()
            await loadArtworkIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            isPlayingState = false
            activeSourceLabel = nil
        }

        isLoading = false
    }

    func present(
        videoId: String,
        title: String,
        metaLine: String?,
        channelName: String?,
        channelAvatarURL: URL?,
        thumbnailURL: URL?,
        channelId: String?
    ) {
        presentation = Presentation(
            id: videoId,
            videoId: videoId,
            title: title,
            metaLine: metaLine,
            channelName: channelName,
            channelAvatarURL: channelAvatarURL,
            thumbnailURL: thumbnailURL,
            channelId: channelId
        )

        Task {
            await resolver.prefetch(videoId: videoId, mode: settings.playbackSourceMode)
        }
    }

    func presentCurrent() {
        guard let currentVideoId else { return }
        presentation = Presentation(
            id: currentVideoId,
            videoId: currentVideoId,
            title: title ?? "Без названия",
            metaLine: metaLine,
            channelName: channelName,
            channelAvatarURL: channelAvatarURL,
            thumbnailURL: thumbnailURL,
            channelId: channelId
        )
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlayingState = false
        } else {
            ensureAudioSessionActive()
            player.play()
            isPlayingState = true
        }
        updateNowPlayingInfo()
    }

    func stop() {
        player?.pause()
        player = nil
        playerStatusObservation = nil
        currentVideoId = nil
        isLoading = false
        presentation = nil
        isPlayingState = false
        descriptionText = nil
        currentPlayerId = nil
        currentArtwork = nil
        activeSourceLabel = nil
        attemptedPipedRecoveryForVideoId = nil
        isRecoveringViaPiped = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        stopPictureInPictureIfNeeded()
        pipController = nil
        playerLayer = nil
        hlsProxy = nil
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active || phase == .background else { return }
#if DEBUG
        print("[ScenePhase] \(phase)")
#endif
        ensureAudioSessionActive()
        if phase == .background, isPlaying, !isDeviceLocked {
            startPictureInPictureIfPossible()
        } else if phase == .active {
            stopPictureInPictureIfNeeded()
        }
        updateNowPlayingInfo()
    }

    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        guard playerLayer !== layer else { return }
        playerLayer = layer
        configurePictureInPicture(for: layer)
    }

    private func makePlayerItem(url: URL, headers: [String: String], playerId: String?) -> AVPlayerItem {
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headersForAsset(url: url, headers: headers)
        ]
        if isHLS(url: url) {
            if shouldBypassHLSProxy(url: url) {
                hlsProxy = nil
                let asset = AVURLAsset(url: url, options: options)
                let item = AVPlayerItem(asset: asset)
                configureForFastStart(item)
                return item
            }

            let proxy = HLSProxy(
                originalURL: url,
                headers: headers,
                playerId: playerId,
                decoder: playbackService
            )
            hlsProxy = proxy
            let asset = AVURLAsset(url: proxy.proxiedURL, options: options)
            asset.resourceLoader.setDelegate(proxy, queue: proxy.queue)
            let item = AVPlayerItem(asset: asset)
            configureForFastStart(item)
            return item
        }

        hlsProxy = nil
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        configureForFastStart(item)
        return item
    }

    private func configureForFastStart(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    private func isHLS(url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains(".m3u8") || lower.contains("hls")
    }

    private func shouldBypassHLSProxy(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    private func headersForAsset(url: URL, headers: [String: String]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return headers }
        if host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            // Signed Googlevideo URLs should be requested without custom headers.
            return [:]
        }
        return headers
    }

    private func probeStream(url: URL, headers: [String: String]) async {
#if DEBUG
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let effectiveHeaders = headersForAsset(url: url, headers: headers)
        effectiveHeaders.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let acceptRanges = http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "unknown"
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
            let prefix = String(data: data.prefix(64), encoding: .utf8) ?? "binary"
            print("[VideoPlayback] probe status=\(status) contentType=\(contentType) acceptRanges=\(acceptRanges) contentLength=\(contentLength) prefix=\(prefix)")
        } catch {
            print("[VideoPlayback] probe failed: \(error)")
        }
#endif
    }

    private func observe(item: AVPlayerItem) {
        playerStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            guard let self else { return }
            if playerItem.status == .failed {
                let nsError = playerItem.error as NSError?
                let code = nsError?.code ?? -1
                let domain = nsError?.domain ?? "AVPlayer"
                let reason = nsError?.localizedFailureReason ?? nsError?.localizedDescription ?? "Unknown"
                let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError)
                let underlyingDesc = underlying?.localizedDescription ?? "none"
                Task { @MainActor in
                    self.errorMessage = "Поток AVPlayer недоступен (\(domain):\(code)) \(reason)"
                    print("[VideoPlayback] AVPlayer failed domain=\(domain) code=\(code) reason=\(reason) underlying=\(underlyingDesc)")
                    await self.recoverViaPipedIfNeeded(triggerError: nsError, underlying: underlying)
                }
            }
        }
    }

    private func recoverViaPipedIfNeeded(triggerError: NSError?, underlying: NSError?) async {
        guard pipedAutoFallbackEnabled else { return }
        guard settings.playbackSourceMode == .auto else { return }
        guard !isRecoveringViaPiped else { return }
        guard activeSourceLabel != "Piped" else { return }
        guard let videoId = currentVideoId else { return }
        guard attemptedPipedRecoveryForVideoId != videoId else { return }
        guard shouldRetryWithPiped(triggerError: triggerError, underlying: underlying) else { return }

        attemptedPipedRecoveryForVideoId = videoId
        isRecoveringViaPiped = true
        isLoading = true

        do {
            let playback = try await resolver.resolve(videoId: videoId, mode: .piped)
            title = playback.title ?? title
            channelName = playback.channelName ?? channelName
            channelId = playback.channelId ?? channelId
            descriptionText = playback.description ?? descriptionText
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            Task {
                await self.probeStream(url: playback.streamURL, headers: playback.headers)
            }
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            ensureAudioSessionActive()
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            errorMessage = nil
            updateNowPlayingInfo()
            await loadArtworkIfNeeded()
            print("[VideoPlayback] recovered via Piped fallback")
        } catch {
            let previous = errorMessage ?? "Поток AVPlayer недоступен."
            errorMessage = "\(previous)\nFallback Piped: \(error.localizedDescription)"
            isPlayingState = false
            print("[VideoPlayback] Piped fallback failed: \(error.localizedDescription)")
        }

        isLoading = false
        isRecoveringViaPiped = false
    }

    private func shouldRetryWithPiped(triggerError: NSError?, underlying: NSError?) -> Bool {
        if let triggerError {
            if triggerError.domain == NSURLErrorDomain && triggerError.code == -1102 {
                return true
            }
            if triggerError.domain == "CoreMediaErrorDomain" && triggerError.code == -12660 {
                return true
            }
            let text = "\(triggerError.localizedDescription) \(triggerError.localizedFailureReason ?? "")".lowercased()
            if text.contains("403") || text.contains("forbidden") || text.contains("permission") {
                return true
            }
        }

        if let underlying {
            if underlying.domain == NSURLErrorDomain && underlying.code == -1102 {
                return true
            }
            if underlying.domain == "CoreMediaErrorDomain" && underlying.code == -12660 {
                return true
            }
            let text = "\(underlying.localizedDescription) \(underlying.localizedFailureReason ?? "")".lowercased()
            if text.contains("403") || text.contains("forbidden") || text.contains("permission") {
                return true
            }
        }

        return false
    }

    private func ensureAudioSessionActive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default
            )
            try session.setActive(true)
#if DEBUG
            print("[AudioSession] category=\(session.category.rawValue) mode=\(session.mode.rawValue) active=\(session.isOtherAudioPlaying ? "other-audio" : "ok")")
#endif
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
#if DEBUG
                print("[AudioSession] fallback category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
#endif
            } catch {
                print("Audio session activation failed: \(error)")
            }
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended {
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), isPlaying {
                ensureAudioSessionActive()
                player?.play()
            }
        }
    }

    private func handleDeviceLock() {
        isDeviceLocked = true
        stopPictureInPictureIfNeeded()
        player?.pause()
        isPlayingState = false
        updateNowPlayingInfo()
    }

    private func configureAudioSession() {
        ensureAudioSessionActive()
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player?.play()
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player?.pause()
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let player = self.player {
                    self.isPlayingState = (player.timeControlStatus == .playing)
                } else {
                    self.isPlayingState = false
                }
                self.updateNowPlayingInfo()
            }
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func updateNowPlayingInfo() {
        guard currentVideoId != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let elapsed = max(0, player?.currentTime().seconds ?? 0)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Без названия",
            MPMediaItemPropertyArtist: channelName ?? "Канал",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed
        ]

        if let duration = player?.currentItem?.duration.seconds,
           duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtworkIfNeeded() async {
        guard let url = thumbnailURL else { return }
        if let cached = artworkCache[url] {
            currentArtwork = cached
            updateNowPlayingInfo()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache[url] = artwork
                currentArtwork = artwork
                updateNowPlayingInfo()
            }
        } catch {
            // Ignore artwork errors.
        }
    }

    private func configurePictureInPicture(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pipController = controller
    }

    private func startPictureInPictureIfPossible() {
        guard let controller = pipController,
              !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    private func stopPictureInPictureIfNeeded() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension PlaybackController: AVPictureInPictureControllerDelegate {}
