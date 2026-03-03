import SwiftUI

struct TrendsView: View {
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @StateObject private var searchViewModel = SearchViewModel()

    var body: some View {
        Group {
            if searchViewModel.isLoading {
                ProgressView("Loading trends...")
            } else if let error = searchViewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            } else if searchViewModel.videos.isEmpty {
                Text("No trends loaded")
                    .foregroundStyle(.secondary)
            } else {
                List(Array(searchViewModel.videos.enumerated()), id: \.offset) { index, item in
                    Button {
                        queueViewModel.startPlayback(with: searchViewModel.videos, at: index)
                    } label: {
                        VideoListRowView(item: item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Trends")
        .task {
            if searchViewModel.query.isEmpty {
                searchViewModel.query = "trending"
                await searchViewModel.search()
            }
        }
    }
}
