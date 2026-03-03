import SwiftUI
import UIKit
import KSPlayer

struct KSVideoSurfaceView: UIViewRepresentable {
    @EnvironmentObject private var queueViewModel: PlaybackQueueViewModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        queueViewModel.attachPlayerContainer(container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        queueViewModel.attachPlayerContainer(uiView)
    }
}
