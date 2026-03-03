import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var playlists: [LocalPlaylist] = []
    @Published private(set) var subscriptions: [SubscriptionChannel] = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let historyKey = "pipepipe.history.v1"
    private let playlistsKey = "pipepipe.playlists.v1"
    private let subscriptionsKey = "pipepipe.subscriptions.v1"
    private let historyLimit = 200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func addToHistory(_ item: VideoItem) {
        history.removeAll(where: { $0.item.id == item.id })
        history.insert(
            HistoryEntry(id: UUID(), item: item, playedAt: Date()),
            at: 0
        )
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(LocalPlaylist(id: UUID(), name: trimmed, videos: [], createdAt: Date()))
        savePlaylists()
    }

    func add(_ item: VideoItem, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].videos.append(item)
        savePlaylists()
    }

    func removeVideo(at offsets: IndexSet, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for offset in offsets.sorted(by: >) where playlists[index].videos.indices.contains(offset) {
            playlists[index].videos.remove(at: offset)
        }
        savePlaylists()
    }

    func removePlaylist(id: UUID) {
        playlists.removeAll(where: { $0.id == id })
        savePlaylists()
    }

    func subscribe(channelId: String, channelName: String) {
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelId.isEmpty, !trimmedName.isEmpty else { return }
        if subscriptions.contains(where: { $0.id == channelId }) {
            return
        }
        subscriptions.append(SubscriptionChannel(id: channelId, name: trimmedName))
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSubscriptions()
    }

    func unsubscribe(channelId: String) {
        subscriptions.removeAll(where: { $0.id == channelId })
        saveSubscriptions()
    }

    func isSubscribed(channelId: String?) -> Bool {
        guard let channelId else { return false }
        return subscriptions.contains(where: { $0.id == channelId })
    }

    func exportSubscriptionsJSON() -> String {
        if let data = try? encoder.encode(subscriptions),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "[]"
    }

    @discardableResult
    func importSubscriptionsJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let imported = try? decoder.decode([SubscriptionChannel].self, from: data) else {
            return false
        }

        var merged = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        for item in imported where !item.id.isEmpty {
            merged[item.id] = item
        }
        subscriptions = Array(merged.values)
        subscriptions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSubscriptions()
        return true
    }

    private func load() {
        if let historyData = defaults.data(forKey: historyKey),
           let decodedHistory = try? decoder.decode([HistoryEntry].self, from: historyData) {
            history = decodedHistory
        }

        if let playlistsData = defaults.data(forKey: playlistsKey),
           let decodedPlaylists = try? decoder.decode([LocalPlaylist].self, from: playlistsData) {
            playlists = decodedPlaylists
        }

        if let subscriptionsData = defaults.data(forKey: subscriptionsKey),
           let decodedSubscriptions = try? decoder.decode([SubscriptionChannel].self, from: subscriptionsData) {
            subscriptions = decodedSubscriptions
        }
    }

    private func saveHistory() {
        if let data = try? encoder.encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private func savePlaylists() {
        if let data = try? encoder.encode(playlists) {
            defaults.set(data, forKey: playlistsKey)
        }
    }

    private func saveSubscriptions() {
        if let data = try? encoder.encode(subscriptions) {
            defaults.set(data, forKey: subscriptionsKey)
        }
    }
}
