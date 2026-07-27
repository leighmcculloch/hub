import Foundation

/// Which session tab a keyboard shortcut selects.
///
/// Kept apart from `Workspace` so the index arithmetic — the part that is easy
/// to get subtly wrong at the ends of the list — can be exercised directly.
enum TabNavigation {
    /// The tab picked by ⌘1…⌘9.
    ///
    /// Follows the convention every browser and terminal uses: ⌘9 is the *last*
    /// tab rather than the ninth, so it stays useful past nine sessions. A
    /// number beyond the end selects nothing rather than clamping, so ⌘4 with
    /// two tabs open leaves the selection alone instead of jumping.
    static func index(forShortcut number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return count - 1 }
        let index = number - 1
        return index < count ? index : nil
    }

    /// The tab `offset` places from `current`, wrapping around both ends so
    /// next/previous never dead-ends. With nothing selected, going forward
    /// starts at the first tab and going back starts at the last.
    static func index(from current: Int?, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset >= 0 ? 0 : count - 1 }
        let next = (current + offset) % count
        return next < 0 ? next + count : next
    }
}
