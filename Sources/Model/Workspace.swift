import Foundation
import SwiftUI

/// Top-level app state: the list of terminal sessions shown as vertical tabs.
final class Workspace: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: TerminalSession.ID?
    @Published var showDiffSidebar: Bool = true

    init() {
        newSession()
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    @discardableResult
    func newSession() -> TerminalSession {
        let session = TerminalSession()
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    func closeSession(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            // Select a neighbouring tab, preferring the one that took its place.
            selectedSessionID = sessions[safe: index]?.id ?? sessions.last?.id
        }
    }

    func closeSelectedSession() {
        if let selected = selectedSession {
            closeSession(selected)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
