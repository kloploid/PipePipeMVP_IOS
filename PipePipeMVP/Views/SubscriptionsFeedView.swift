import SwiftUI

struct SubscriptionsFeedView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @StateObject private var viewModel = FeedViewModel()
    @State private var isManagePresented = false

    var body: some View {
        List {
            if viewModel.isLoading {
                Section {
                    ProgressView("Refreshing subscriptions feed...")
                }
            } else if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if viewModel.items.isEmpty {
                Section {
                    Text("Нет роликов по подпискам. Откройте Manage и проверьте список каналов.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(viewModel.items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                queueViewModel.startPlayback(with: viewModel.items, at: index)
                            } label: {
                                VideoListRowView(item: item)
                            }
                            .buttonStyle(.plain)

                            if let channelId = item.channelID {
                                NavigationLink {
                                    ChannelVideosView(
                                        channel: SubscriptionChannel(
                                            id: channelId,
                                            name: item.channelTitle
                                        )
                                    )
                                    .environmentObject(queueViewModel)
                                    .environmentObject(libraryViewModel)
                                } label: {
                                    Text("Open channel page")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Manage") {
                    isManagePresented = true
                }
            }
        }
        .task {
            await viewModel.refresh(subscriptions: libraryViewModel.subscriptions)
        }
        .onChange(of: libraryViewModel.subscriptions) { _ in
            Task { await viewModel.refresh(subscriptions: libraryViewModel.subscriptions) }
        }
        .sheet(isPresented: $isManagePresented) {
            NavigationStack {
                SubscriptionsView()
                    .environmentObject(libraryViewModel)
                    .environmentObject(queueViewModel)
            }
        }
    }
}
