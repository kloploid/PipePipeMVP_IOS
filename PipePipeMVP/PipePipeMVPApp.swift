import SwiftUI

@main
struct PipePipeMVPApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var queueViewModel = PlaybackQueueViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(queueViewModel)
                .environmentObject(libraryViewModel)
        }
        .onChange(of: scenePhase) { newPhase in
            queueViewModel.handleScenePhase(newPhase)
        }
    }
}
