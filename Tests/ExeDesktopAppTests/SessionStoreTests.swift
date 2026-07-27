import XCTest
@testable import ExeDesktopApp

/// Persisting open tabs so quitting doesn't lose the workspace.
final class SessionStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsThroughTheFile() {
        let sessions = [
            PersistedSession(destination: "a.exe.xyz", title: "A", vmName: "a"),
            PersistedSession(destination: "b.exe.xyz", title: "B", vmName: nil),
        ]
        store.save(sessions)
        XCTAssertEqual(store.load(), sessions)
    }

    /// A first launch has no file at all, which must read as "no tabs" rather
    /// than failing.
    func testLoadsEmptyWhenTheFileIsAbsent() {
        XCTAssertEqual(store.load(), [])
    }

    /// A truncated or hand-mangled file must not prevent the app starting.
    func testLoadsEmptyWhenTheFileIsCorrupt() throws {
        let url = directory.appendingPathComponent("sessions.json")
        try Data("not json {".utf8).write(to: url)
        XCTAssertEqual(store.load(), [])
    }

    func testSavingEmptyClearsPreviousSessions() {
        store.save([PersistedSession(destination: "a.exe.xyz", title: "A", vmName: "a")])
        store.save([])
        XCTAssertEqual(store.load(), [])
    }

    // MARK: - Which tabs come back

    private let persisted = [
        PersistedSession(destination: "alive.exe.xyz", title: "Alive", vmName: "alive"),
        PersistedSession(destination: "deleted.exe.xyz", title: "Gone", vmName: "deleted"),
    ]

    /// A VM deleted since last launch shouldn't return as a dead tab.
    func testDropsTabsWhoseVMNoLongerExists() {
        let restorable = SessionStore.restorable(
            persisted: persisted, knownDestinations: ["alive.exe.xyz"])
        XCTAssertEqual(restorable.map(\.destination), ["alive.exe.xyz"])
    }

    /// But an empty VM list means the lookup failed or there's no token —
    /// trusting it would silently wipe the workspace over a network blip.
    func testKeepsAllTabsWhenTheVMListIsUnavailable() {
        XCTAssertEqual(
            SessionStore.restorable(persisted: persisted, knownDestinations: []),
            persisted)
    }

    func testRestorableIsEmptyWhenNothingWasPersisted() {
        XCTAssertTrue(
            SessionStore.restorable(persisted: [], knownDestinations: ["a.exe.xyz"]).isEmpty)
    }

    func testOrderIsPreservedSoTabsComeBackWhereTheyWere() {
        let many = (1...5).map {
            PersistedSession(destination: "vm\($0).exe.xyz", title: "T\($0)", vmName: "vm\($0)")
        }
        store.save(many)
        XCTAssertEqual(store.load().map(\.destination), many.map(\.destination))
    }
}
