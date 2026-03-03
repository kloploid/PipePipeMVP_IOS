import SwiftUI

struct SearchTabView: View {
    @StateObject var viewModel: SearchViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @EnvironmentObject private var libraryViewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search videos", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                Button("Go") {
                    Task { await viewModel.search() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Picker("Filter", selection: $viewModel.selectedFilter) {
                    ForEach(SearchFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            Picker("Sort", selection: $viewModel.selectedSort) {
                ForEach(SearchSort.allCases) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding(.top, 20)
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            } else if viewModel.visibleVideos.isEmpty {
                Spacer()
                Text(viewModel.videos.isEmpty ? "Type a query and tap Go" : "No results for selected filter")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(Array(viewModel.visibleVideos.enumerated()), id: \.offset) { index, item in
                    Button {
                        queueViewModel.startPlayback(with: viewModel.visibleVideos, at: index)
                    } label: {
                        HStack(spacing: 12) {
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
                            .frame(width: 88, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(item.channelTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let durationText = item.durationText {
                                    Text(durationText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if item.isLive {
                                    Text("LIVE")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play next") {
                            queueViewModel.playNext(item)
                        }
                        Button("Add to queue") {
                            queueViewModel.enqueue(item)
                        }
                        if let channelID = item.channelID {
                            if libraryViewModel.isSubscribed(channelId: channelID) {
                                Button("Unsubscribe channel") {
                                    libraryViewModel.unsubscribe(channelId: channelID)
                                }
                            } else {
                                Button("Subscribe channel") {
                                    libraryViewModel.subscribe(
                                        channelId: channelID,
                                        channelName: item.channelTitle
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Search")
    }
}
