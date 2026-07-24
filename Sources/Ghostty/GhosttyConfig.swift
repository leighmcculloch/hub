import GhosttyKit

/// Owns a `ghostty_config_t`. We load the user's default config files (e.g.
/// `~/.config/ghostty/config`) so the embedded terminal matches their normal
/// Ghostty setup, then finalize it.
final class GhosttyConfig {
    let handle: ghostty_config_t

    init() {
        // GHOSTTY API: config lifecycle — new -> load defaults -> finalize.
        handle = ghostty_config_new()
        ghostty_config_load_default_files(handle)
        ghostty_config_finalize(handle)
    }

    deinit {
        ghostty_config_free(handle)
    }
}
