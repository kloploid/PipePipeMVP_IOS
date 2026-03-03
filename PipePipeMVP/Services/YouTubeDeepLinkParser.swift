import Foundation

enum YouTubeDeepLinkParser {
    static func extractVideoID(from url: URL) -> String? {
        if url.scheme == "vnd.youtube" || url.scheme == "vnd.youtube.launch" {
            if let host = url.host, host.count == 11 {
                return host
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        }

        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path

        if host == "youtu.be" {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }

        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if path == "/watch" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            }
            if path.hasPrefix("/shorts/") {
                return String(path.dropFirst("/shorts/".count)).split(separator: "/").first.map(String.init)
            }
            if path.hasPrefix("/embed/") {
                return String(path.dropFirst("/embed/".count)).split(separator: "/").first.map(String.init)
            }
            if path.hasPrefix("/v/") {
                return String(path.dropFirst("/v/".count)).split(separator: "/").first.map(String.init)
            }
        }

        return nil
    }
}
