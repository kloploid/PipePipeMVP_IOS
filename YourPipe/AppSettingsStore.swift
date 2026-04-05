import Foundation

enum PlaybackSourceMode: String, CaseIterable, Identifiable {
    case auto
    case direct
    case piped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .direct: return "Прямой YouTube"
        case .piped: return "Piped proxy"
        }
    }
}

final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @Published var playbackSourceMode: PlaybackSourceMode {
        didSet {
            userDefaults.set(playbackSourceMode.rawValue, forKey: Keys.playbackSourceMode)
        }
    }

    private enum Keys {
        static let playbackSourceMode = "settings.playbackSourceMode"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: Keys.playbackSourceMode),
           let mode = PlaybackSourceMode(rawValue: raw) {
            self.playbackSourceMode = mode
        } else {
            self.playbackSourceMode = .direct
        }
    }
}
