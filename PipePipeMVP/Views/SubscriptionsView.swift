import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionsView: View {
    @EnvironmentObject private var libraryViewModel: LibraryViewModel
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel
    @State private var importText = ""
    @State private var statusMessage: String?
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false

    var body: some View {
        List {
            Section("Import / Export") {
                ShareLink(item: libraryViewModel.exportSubscriptionsJSON()) {
                    Label("Export subscriptions JSON", systemImage: "square.and.arrow.up")
                }

                Button("Export to file") {
                    isExporterPresented = true
                }

                Button("Import from file") {
                    isImporterPresented = true
                }

                TextEditor(text: $importText)
                    .frame(minHeight: 120)
                    .font(.system(.footnote, design: .monospaced))

                Button("Import JSON") {
                    let ok = libraryViewModel.importSubscriptionsJSON(importText)
                    statusMessage = ok ? "Imported" : "Import failed"
                }
            }

            Section("Channels") {
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name)
                                Text(channel.id)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indices in
                        for index in indices {
                            let channel = libraryViewModel.subscriptions[index]
                            libraryViewModel.unsubscribe(channelId: channel.id)
                        }
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Manage subscriptions")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let json = String(decoding: data, as: UTF8.self)
                    let ok = libraryViewModel.importSubscriptionsJSON(json)
                    statusMessage = ok ? "Imported from file" : "Import failed"
                } catch {
                    statusMessage = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: SubscriptionsFileDocument(text: libraryViewModel.exportSubscriptionsJSON()),
            contentType: .json,
            defaultFilename: "pipepipe_subscriptions"
        ) { result in
            switch result {
            case .success:
                statusMessage = "Exported"
            case .failure(let error):
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
