import Foundation

enum FeedSortMode: String, CaseIterable, Identifiable {
    case latest = "Latest"
    case channel = "Channel"
    case title = "Title"

    var id: String { rawValue }
}

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sortMode: FeedSortMode = .latest

    private let service: VideoSearchServicing

    init(service: VideoSearchServicing = VideoSearchService()) {
        self.service = service
    }

    func refresh(subscriptions: [SubscriptionChannel]) async {
        guard !subscriptions.isEmpty else {
            items = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let indexedResults = await withTaskGroup(
            of: (Int, [VideoItem]?).self,
            returning: [(Int, [VideoItem])].self
        ) { group in
            for (index, channel) in subscriptions.enumerated() {
                group.addTask {
                    do {
                        let videos = try await self.service.fetchChannelVideos(
                            channelId: channel.id,
                            limit: 12
                        )
                        return (index, videos)
                    } catch {
                        return (index, nil)
                    }
                }
            }

            var results: [(Int, [VideoItem])] = []
            for await result in group {
                if let videos = result.1 {
                    results.append((result.0, videos))
                }
            }
            return results
        }

        let merged = indexedResults
            .sorted { $0.0 < $1.0 }
            .flatMap { $0.1 }

        var seen = Set<String>()
        let deduped = merged.filter { item in
            if seen.contains(item.id) { return false }
            seen.insert(item.id)
            return true
        }

        items = sort(items: deduped)
        if items.isEmpty {
            errorMessage = "Feed is empty. Channel may have no public videos or YouTube blocked this request."
        }
    }

    func applySort() {
        items = sort(items: items)
    }

    private func sort(items: [VideoItem]) -> [VideoItem] {
        switch sortMode {
        case .latest:
            return items.sorted { lhs, rhs in
                let lhsAge = relativeAgeSeconds(lhs.publishedText)
                let rhsAge = relativeAgeSeconds(rhs.publishedText)
                if lhsAge != rhsAge { return lhsAge < rhsAge }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .channel:
            return items.sorted {
                $0.channelTitle.localizedCaseInsensitiveCompare($1.channelTitle) == .orderedAscending
            }
        case .title:
            return items.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private func relativeAgeSeconds(_ text: String?) -> Int {
        guard var value = text?.lowercased() else { return Int.max }
        value = value.replacingOccurrences(of: "streamed ", with: "")
        value = value.replacingOccurrences(of: "ago", with: "")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.contains("just now") {
            return 0
        }

        let parts = value.split(separator: " ")
        guard parts.count >= 2, let number = Int(parts[0]) else {
            return Int.max
        }

        let unit = String(parts[1])
        switch unit {
        case let u where u.hasPrefix("second"):
            return number
        case let u where u.hasPrefix("minute"):
            return number * 60
        case let u where u.hasPrefix("hour"):
            return number * 3_600
        case let u where u.hasPrefix("day"):
            return number * 86_400
        case let u where u.hasPrefix("week"):
            return number * 604_800
        case let u where u.hasPrefix("month"):
            return number * 2_629_800
        case let u where u.hasPrefix("year"):
            return number * 31_557_600
        default:
            return Int.max
        }
    }
}
