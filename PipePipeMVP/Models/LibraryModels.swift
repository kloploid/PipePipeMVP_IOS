import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let item: VideoItem
    let playedAt: Date
}

struct LocalPlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var videos: [VideoItem]
    let createdAt: Date
}

struct SubscriptionChannel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
}
