import SwiftUI

struct SettingsView: View {
    @AppStorage("setting_show_played") private var showPlayed = true
    @AppStorage("setting_autoplay") private var autoPlay = true
    @AppStorage("setting_sponsorblock_enabled") private var sponsorBlockEnabled = true

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Auto play", isOn: $autoPlay)
                Toggle("SponsorBlock (auto-skip)", isOn: $sponsorBlockEnabled)
            }
            Section("Feed") {
                Toggle("Show played videos", isOn: $showPlayed)
            }
            Section("About") {
                Text("PipePipe-style iOS MVP")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
