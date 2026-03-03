import Foundation

struct VideoItem: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let channelTitle: String
    let channelID: String?
    let thumbnailURL: URL?
    let durationText: String?
    let publishedText: String?
    let isLive: Bool

    var embedURL: URL? {
        URL(string: "https://www.youtube.com/embed/\(id)?playsinline=1")
    }
}
