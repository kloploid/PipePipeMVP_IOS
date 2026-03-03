import Foundation

enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case videos = "Videos"
    case live = "Live"

    var id: String { rawValue }
}

enum SearchSort: String, CaseIterable, Identifiable {
    case relevance = "Relevance"
    case title = "Title"
    case channel = "Channel"

    var id: String { rawValue }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var videos: [VideoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedFilter: SearchFilter = .all
    @Published var selectedSort: SearchSort = .relevance

    private let service: VideoSearchServicing

    init(service: VideoSearchServicing = VideoSearchService()) {
        self.service = service
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            videos = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            videos = try await service.search(query: trimmed)
        } catch {
            videos = []
            errorMessage = error.localizedDescription
        }
    }

    var visibleVideos: [VideoItem] {
        let filtered: [VideoItem]
        switch selectedFilter {
        case .all:
            filtered = videos
        case .videos:
            filtered = videos.filter { !$0.isLive }
        case .live:
            filtered = videos.filter { $0.isLive }
        }

        switch selectedSort {
        case .relevance:
            return filtered
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .channel:
            return filtered.sorted { $0.channelTitle.localizedCaseInsensitiveCompare($1.channelTitle) == .orderedAscending }
        }
    }
}
