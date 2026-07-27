import XCTest
@testable import ExeDesktopApp

/// Which tab ⌘1…⌘9 and next/previous land on.
final class TabNavigationTests: XCTestCase {

    // MARK: - ⌘1…⌘9

    func testNumbersMapToTheirPosition() {
        XCTAssertEqual(TabNavigation.index(forShortcut: 1, count: 5), 0)
        XCTAssertEqual(TabNavigation.index(forShortcut: 3, count: 5), 2)
        XCTAssertEqual(TabNavigation.index(forShortcut: 5, count: 5), 4)
    }

    /// ⌘9 is the last tab, not the ninth — otherwise it would be dead in every
    /// workspace with fewer than nine sessions.
    func testNineSelectsTheLastTab() {
        XCTAssertEqual(TabNavigation.index(forShortcut: 9, count: 3), 2)
        XCTAssertEqual(TabNavigation.index(forShortcut: 9, count: 1), 0)
        XCTAssertEqual(TabNavigation.index(forShortcut: 9, count: 20), 19)
    }

    /// With nine or more tabs, ⌘9 is still the last one rather than index 8.
    func testNineIsTheLastTabEvenWhenTheNinthExists() {
        XCTAssertEqual(TabNavigation.index(forShortcut: 9, count: 12), 11)
    }

    /// Pressing a number past the end should leave the selection alone, not
    /// clamp to the nearest tab.
    func testNumbersBeyondTheEndSelectNothing() {
        XCTAssertNil(TabNavigation.index(forShortcut: 4, count: 2))
        XCTAssertNil(TabNavigation.index(forShortcut: 8, count: 7))
    }

    func testNothingIsSelectedWithNoTabs() {
        for number in 1...9 {
            XCTAssertNil(TabNavigation.index(forShortcut: number, count: 0),
                         "⌘\(number) with no tabs")
        }
    }

    /// ⌘0 is bound to resetting the font size, so it must not be treated as a
    /// tab number.
    func testZeroIsNotATabShortcut() {
        XCTAssertNil(TabNavigation.index(forShortcut: 0, count: 5))
    }

    // MARK: - Next / previous

    func testNextAndPreviousStepThroughTheTabs() {
        XCTAssertEqual(TabNavigation.index(from: 1, offset: 1, count: 4), 2)
        XCTAssertEqual(TabNavigation.index(from: 1, offset: -1, count: 4), 0)
    }

    /// Wrapping is the point of the shortcut: reaching the end shouldn't stop
    /// the user cycling.
    func testWrapsPastBothEnds() {
        XCTAssertEqual(TabNavigation.index(from: 3, offset: 1, count: 4), 0)
        XCTAssertEqual(TabNavigation.index(from: 0, offset: -1, count: 4), 3)
    }

    /// The sidebar can show tabs with none selected (the "New Session" state),
    /// where next/previous should still start somewhere sensible.
    func testStartsAtAnEndWhenNothingIsSelected() {
        XCTAssertEqual(TabNavigation.index(from: nil, offset: 1, count: 4), 0)
        XCTAssertEqual(TabNavigation.index(from: nil, offset: -1, count: 4), 3)
    }

    func testASingleTabStaysSelected() {
        XCTAssertEqual(TabNavigation.index(from: 0, offset: 1, count: 1), 0)
        XCTAssertEqual(TabNavigation.index(from: 0, offset: -1, count: 1), 0)
    }

    func testNothingToSelectWithNoTabs() {
        XCTAssertNil(TabNavigation.index(from: nil, offset: 1, count: 0))
        XCTAssertNil(TabNavigation.index(from: 0, offset: -1, count: 0))
    }

    /// Repeated presses must cycle the whole list and come back around, which a
    /// sign error at one end would break without failing a single step.
    func testCyclingForwardVisitsEveryTabThenReturns() {
        var index: Int? = 0
        var visited: [Int] = [0]
        for _ in 0..<4 {
            index = TabNavigation.index(from: index, offset: 1, count: 4)
            visited.append(index!)
        }
        XCTAssertEqual(visited, [0, 1, 2, 3, 0])
    }

    func testCyclingBackwardVisitsEveryTabThenReturns() {
        var index: Int? = 0
        var visited: [Int] = [0]
        for _ in 0..<4 {
            index = TabNavigation.index(from: index, offset: -1, count: 4)
            visited.append(index!)
        }
        XCTAssertEqual(visited, [0, 3, 2, 1, 0])
    }

    /// Every result has to be a usable index — an out-of-range one would trap
    /// when the workspace subscripts its session list.
    func testEveryResultIsAValidIndex() {
        for count in 1...12 {
            for number in 0...10 {
                if let index = TabNavigation.index(forShortcut: number, count: count) {
                    XCTAssertTrue((0..<count).contains(index), "⌘\(number) of \(count)")
                }
            }
            for current in 0..<count {
                for offset in [-3, -1, 1, 3] {
                    let index = TabNavigation.index(from: current, offset: offset, count: count)
                    XCTAssertTrue((0..<count).contains(index!),
                                  "\(current) \(offset >= 0 ? "+" : "")\(offset) of \(count)")
                }
            }
        }
    }
}
