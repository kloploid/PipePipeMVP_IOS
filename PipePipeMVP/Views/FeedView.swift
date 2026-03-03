import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @StateObject private var viewModel = FeedViewModel()

    var body: some View {
        List {
            Section {
                Text("Этот раздел показывает последние найденные ролики из каналов, на которые вы подписаны.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoading {
                Section {
                    ProgressView("Refreshing feed...")
                }
            } else if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if viewModel.items.isEmpty {
                Section {
                    Text("Feed пуст. Добавьте подписки в разделе Subs.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(viewModel.items.enumerated()), id: \.offset) { index, item in
                        Button {
                            queueViewModel.startPlayback(with: viewModel.items, at: index)
                        } label: {
                            VideoListRowView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Feed")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Sort", selection: $viewModel.sortMode) {
                        ForEach(FeedSortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") {
                    Task { await viewModel.refresh(subscriptions: libraryViewModel.subscriptions) }
                }
            }
        }
        .task {
            await viewModel.refresh(subscriptions: libraryViewModel.subscriptions)
        }
        .onChange(of: libraryViewModel.subscriptions) { _ in
            Task { await viewModel.refresh(subscriptions: libraryViewModel.subscriptions) }
        }
        .onChange(of: viewModel.sortMode) { _ in
            viewModel.applySort()
        }
    }
}
