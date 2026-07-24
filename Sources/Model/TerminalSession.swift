import Foundation
import SwiftUI

/// One terminal tab: a libghostty surface plus the observable state the UI binds
/// to (its title and current working directory).
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published var title: String = "Terminal"
    /// The shell's current working directory, updated from OSC 7 via libghostty.
    @Published var workingDirectory: URL?

    let surfaceView: SurfaceView

    init(app: GhosttyApp) {
        surfaceView = SurfaceView(app: app)
        surfaceView.onTitleChange = { [weak self] title in
            self?.title = title
        }
        surfaceView.onPwdChange = { [weak self] pwd in
            self?.workingDirectory = URL(fileURLWithPath: pwd)
        }
    }

    /// A short label for the tab strip.
    var displayName: String {
        if let dir = workingDirectory {
            return dir.lastPathComponent
        }
        return title
    }
}
