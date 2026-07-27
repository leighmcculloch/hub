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
        let workspace = PersistedWorkspace(
            sessions: [
                PersistedSession(destination: "a.exe.xyz", title: "A", vmName: "a"),
                PersistedSession(destination: "b.exe.xyz", title: "B", vmName: nil),
            ],
            selected: "b.exe.xyz")
        store.save(workspace)
        XCTAssertEqual(store.load(), workspace)
    }

    /// A first launch has no file at all, which must read as "no tabs" rather
    /// than failing.
    func testLoadsEmptyWhenTheFileIsAbsent() {
        XCTAssertEqual(store.load(), PersistedWorkspace())
    }

    /// A truncated or hand-mangled file must not prevent the app starting.
    func testLoadsEmptyWhenTheFileIsCorrupt() throws {
        let url = directory.appendingPathComponent("sessions.json")
        try Data("not json {".utf8).write(to: url)
        XCTAssertEqual(store.load(), PersistedWorkspace())
    }

    func testSavingEmptyClearsPreviousSessions() {
        store.save(PersistedWorkspace(
            sessions: [PersistedSession(destination: "a.exe.xyz", title: "A", vmName: "a")]))
        store.save(PersistedWorkspace())
        XCTAssertEqual(store.load(), PersistedWorkspace())
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
        store.save(PersistedWorkspace(sessions: many))
        XCTAssertEqual(store.load().sessions.map(\.destination), many.map(\.destination))
    }

    // MARK: - Which tab comes back in front

    /// Landing on the first tab after a restart loses your place for no reason.
    func testTheActiveTabIsTheOneRestored() {
        XCTAssertEqual(
            SessionStore.restorableSelection("deleted.exe.xyz", in: persisted),
            "deleted.exe.xyz")
    }

    /// When the active tab's VM is gone it isn't in the restorable list, so the
    /// selection has to fall back rather than pointing at nothing.
    func testFallsBackToTheFirstTabWhenTheActiveOneIsGone() {
        let alive = Array(persisted.prefix(1))
        XCTAssertEqual(
            SessionStore.restorableSelection("deleted.exe.xyz", in: alive),
            "alive.exe.xyz")
    }

    /// A file written before the selection was recorded has none.
    func testFallsBackToTheFirstTabWhenNothingWasRecorded() {
        XCTAssertEqual(SessionStore.restorableSelection(nil, in: persisted), "alive.exe.xyz")
    }

    func testNoSelectionWhenThereAreNoTabs() {
        XCTAssertNil(SessionStore.restorableSelection("a.exe.xyz", in: []))
        XCTAssertNil(SessionStore.restorableSelection(nil, in: []))
    }

    // MARK: - Reading a file from an older build

    /// The previous format was a bare array. Failing to read it would empty the
    /// workspace on upgrade — the exact thing this store exists to prevent.
    func testReadsTheOldBareArrayFormat() throws {
        let legacy = """
        [{"destination":"a.exe.xyz","title":"A","vmName":"a"},
         {"destination":"b.exe.xyz","title":"B"}]
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("sessions.json"))

        let loaded = store.load()
        XCTAssertEqual(loaded.sessions.map(\.destination), ["a.exe.xyz", "b.exe.xyz"])
        XCTAssertNil(loaded.selected)
    }

    /// And once re-saved it is in the new shape, without a second migration.
    func testAnUpgradedFileKeepsItsSelectionAfterwards() throws {
        let legacy = #"[{"destination":"a.exe.xyz","title":"A"}]"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("sessions.json"))

        var loaded = store.load()
        XCTAssertEqual(loaded.sessions.map(\.destination), ["a.exe.xyz"],
                       "the upgrade dropped the tabs it was meant to carry over")
        loaded.selected = "a.exe.xyz"
        store.save(loaded)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.selected, "a.exe.xyz")
        XCTAssertEqual(reloaded.sessions.map(\.destination), ["a.exe.xyz"])
    }

    /// A newer file must not be mistaken for the old shape or vice versa.
    func testTheTwoFormatsAreDistinguished() throws {
        let url = directory.appendingPathComponent("sessions.json")
        try Data(#"{"sessions":[{"destination":"x.exe.xyz","title":"X"}],"selected":"x.exe.xyz"}"#.utf8)
            .write(to: url)
        XCTAssertEqual(store.load().selected, "x.exe.xyz")
    }
}
