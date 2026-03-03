import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel

    var body: some View {
        List {
            Section {
                if libraryViewModel.history.isEmpty {
                    Text("History is empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(libraryViewModel.history.enumerated()), id: \.offset) { index, entry in
                        Button {
                            let videos = libraryViewModel.history.map(\.item)
                            queueViewModel.startPlayback(with: videos, at: index)
                        } label: {
                            VideoListRowView(item: entry.item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Watch history")
                    Spacer()
                    Button("Clear") {
                        libraryViewModel.clearHistory()
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
    }
}
