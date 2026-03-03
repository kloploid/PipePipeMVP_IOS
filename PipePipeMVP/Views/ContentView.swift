import SwiftUI

enum RootPage: String, Hashable, CaseIterable, Identifiable {
    case subscriptionsHome
    case trends
    case allSubscriptionsFeed
    case history
    case settings
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscriptionsHome: return "Subscriptions"
        case .trends: return "Trends"
        case .allSubscriptionsFeed: return "All subscriptions feed"
        case .history: return "History"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .subscriptionsHome: return "house"
        case .trends: return "flame"
        case .allSubscriptionsFeed: return "dot.radiowaves.left.and.right"
        case .history: return "clock"
        case .settings: return "gearshape"
        case .search: return "magnifyingglass"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var selectedPage: RootPage? = .subscriptionsHome

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                List(selection: $selectedPage) {
                    NavigationLink(value: RootPage.subscriptionsHome) {
                        Label("Subscriptions", systemImage: RootPage.subscriptionsHome.icon)
                    }
                    NavigationLink(value: RootPage.trends) {
                        Label("Trends", systemImage: RootPage.trends.icon)
                    }
                    NavigationLink(value: RootPage.allSubscriptionsFeed) {
                        Label("All subscriptions feed", systemImage: RootPage.allSubscriptionsFeed.icon)
                    }
                    NavigationLink(value: RootPage.history) {
                        Label("History", systemImage: RootPage.history.icon)
                    }
                    NavigationLink(value: RootPage.settings) {
                        Label("Settings", systemImage: RootPage.settings.icon)
                    }
                }
                .navigationTitle("PipePipe")
            } detail: {
                detailView(for: selectedPage ?? .subscriptionsHome)
            }
            .navigationSplitViewStyle(.balanced)

            if let item = queueViewModel.currentItem {
                MiniPlayerBar(item: item)
                    .environmentObject(queueViewModel)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $queueViewModel.isPlayerPresented) {
            if let current = queueViewModel.currentItem {
                NavigationStack {
                    VideoPlayerScreen(initialVideoID: current.id)
                        .environmentObject(queueViewModel)
                        .environmentObject(libraryViewModel)
                }
            }
        }
        .onOpenURL { url in
            guard let videoID = YouTubeDeepLinkParser.extractVideoID(from: url) else { return }
            queueViewModel.ensureCurrent(videoId: videoID)
            queueViewModel.presentPlayer()
        }
    }

    @ViewBuilder
    private func detailView(for page: RootPage) -> some View {
        switch page {
        case .subscriptionsHome:
            NavigationStack {
                SubscriptionsHomeView(
                    onSearchTapped: {
                        selectedPage = .search
                    },
                    onAllSubscriptionsFeedTapped: {
                        selectedPage = .allSubscriptionsFeed
                    }
                )
                .environmentObject(libraryViewModel)
                .environmentObject(queueViewModel)
            }
        case .trends:
            NavigationStack {
                TrendsView()
                    .environmentObject(queueViewModel)
            }
        case .allSubscriptionsFeed:
            NavigationStack {
                SubscriptionsFeedView()
                    .environmentObject(libraryViewModel)
                    .environmentObject(queueViewModel)
            }
        case .history:
            NavigationStack {
                HistoryView()
                    .environmentObject(libraryViewModel)
                    .environmentObject(queueViewModel)
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        case .search:
            NavigationStack {
                SearchTabView(viewModel: searchViewModel)
                    .environmentObject(queueViewModel)
                    .environmentObject(libraryViewModel)
            }
        }
    }
}

private struct MiniPlayerBar: View {
    let item: VideoItem
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                queueViewModel.presentPlayer()
            } label: {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button {
                queueViewModel.presentPlayer()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(item.channelTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                queueViewModel.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button {
                queueViewModel.togglePlayPause()
            } label: {
                Image(systemName: queueViewModel.isPlaying
                    ? "pause.fill"
                    : "play.fill")
            }
            .buttonStyle(.plain)

            Button {
                queueViewModel.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
