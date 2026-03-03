import SwiftUI

struct ChannelVideosView: View {
    let channel: SubscriptionChannel

    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @StateObject private var feedViewModel = FeedViewModel()

    var body: some View {
        Group {
            if feedViewModel.isLoading {
                ProgressView("Loading channel videos...")
            } else if let error = feedViewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
            } else if feedViewModel.items.isEmpty {
                Text("No videos found for this channel.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(Array(feedViewModel.items.enumerated()), id: \.offset) { index, item in
                    Button {
                        queueViewModel.startPlayback(with: feedViewModel.items, at: index)
                    } label: {
                        VideoListRowView(item: item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(channel.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if libraryViewModel.isSubscribed(channelId: channel.id) {
                    Button("Unsubscribe") {
                        libraryViewModel.unsubscribe(channelId: channel.id)
                    }
                } else {
                    Button("Subscribe") {
                        libraryViewModel.subscribe(channelId: channel.id, channelName: channel.name)
                    }
                }
            }
        }
        .task {
            await feedViewModel.refresh(subscriptions: [channel])
        }
    }
}
