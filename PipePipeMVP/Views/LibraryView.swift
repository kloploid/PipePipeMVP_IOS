import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @State private var newPlaylistName = ""

    var body: some View {
        List {
            Section {
                if libraryViewModel.history.isEmpty {
                    Text("No history yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryViewModel.history) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.item.title)
                                .lineLimit(2)
                            HStack {
                                Text(entry.item.channelTitle)
                                Text("•")
                                Text(entry.playedAt, style: .relative)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button("Clear") {
                        libraryViewModel.clearHistory()
                    }
                    .font(.caption)
                }
            }

            Section("Create playlist") {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Create") {
                    libraryViewModel.createPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
            }

            Section("Playlists") {
                if libraryViewModel.playlists.isEmpty {
                    Text("No playlists yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraryViewModel.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                                .environmentObject(queueViewModel)
                                .environmentObject(libraryViewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                Text("\(playlist.videos.count) videos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let playlist = libraryViewModel.playlists[index]
                            libraryViewModel.removePlaylist(id: playlist.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
    }
}
