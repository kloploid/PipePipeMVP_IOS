import Foundation

struct SponsorSegment: Decodable {
    let segment: [Double]
    let category: String
    let actionType: String?

    var start: Double { segment.first ?? 0 }
    var end: Double { segment.count > 1 ? segment[1] : 0 }
}

protocol SponsorBlockServicing {
    func fetchSegments(videoID: String) async throws -> [SponsorSegment]
}

struct SponsorBlockService: SponsorBlockServicing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSegments(videoID: String) async throws -> [SponsorSegment] {
        guard var components = URLComponents(
            string: "https://sponsor.ajay.app/api/skipSegments"
        ) else {
            return []
        }

        let categories = """
        ["sponsor","selfpromo","interaction","intro","outro","preview","music_offtopic"]
        """

        components.queryItems = [
            URLQueryItem(name: "videoID", value: videoID),
            URLQueryItem(name: "categories", value: categories),
            URLQueryItem(name: "actionTypes", value: #"["skip"]"#)
        ]

        guard let url = components.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }

        let segments = (try? JSONDecoder().decode([SponsorSegment].self, from: data)) ?? []
        return segments.filter { $0.end > $0.start }
    }
}
