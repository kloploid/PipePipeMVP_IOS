import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @EnvironmentObject private var libraryViewModel: LibraryViewModel

    private var playlist: LocalPlaylist? {
        libraryViewModel.playlists.first(where: { $0.id == playlistID })
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    ForEach(Array(playlist.videos.enumerated()), id: \.offset) { index, item in
                        NavigationLink {
                            VideoPlayerScreen(initialVideoID: item.id)
                                .environmentObject(queueViewModel)
                                .environmentObject(libraryViewModel)
                                .onAppear {
                                    queueViewModel.startPlayback(with: playlist.videos, at: index)
                                }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .lineLimit(2)
                                Text(item.channelTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        libraryViewModel.removeVideo(at: offsets, from: playlist.id)
                    }
                }
            } else {
                Text("Playlist not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
    }
}
