import SwiftUI

struct SubscriptionsHomeView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel

    let onSearchTapped: () -> Void
    let onAllSubscriptionsFeedTapped: () -> Void

    var body: some View {
        List {
            Section {
                Button {
                    onSearchTapped()
                } label: {
                    Label("Search on YouTube", systemImage: "magnifyingglass")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Feed groups") {
                HStack {
                    Button {
                        onAllSubscriptionsFeedTapped()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 16, weight: .bold))
                            Text("ALL")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .frame(width: 64, height: 48)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }

            Section("Subscriptions") {
                if libraryViewModel.subscriptions.isEmpty {
                    Text("No subscriptions yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryViewModel.subscriptions) { channel in
                        NavigationLink {
                            ChannelVideosView(channel: channel)
                                .environmentObject(queueViewModel)
                                .environmentObject(libraryViewModel)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(String(channel.name.prefix(1)).uppercased())
                                            .font(.caption)
                                            .fontWeight(.bold)
                                    )
                                Text(channel.name)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Subscriptions")
    }
}
