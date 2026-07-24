import GhosttyKit

/// Namespace and one-time global initialization for libghostty.
///
/// libghostty keeps process-global state (logging, signal handling, the global
/// allocator) that must be set up exactly once before any `GhosttyApp` is
/// created.
enum Ghostty {
    private static var didInitialize = false

    static func initializeOnce() {
        guard !didInitialize else { return }
        didInitialize = true

        // GHOSTTY API: recent libghostty takes the process argv so it can honor
        // CLI actions; older builds declared `ghostty_init(void)`. Adjust if the
        // header disagrees.
        _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
    }
}
