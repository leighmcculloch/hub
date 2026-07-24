import AppKit
import GhosttyKit

/// Wraps a single `ghostty_app_t`. The whole workspace shares one app instance;
/// every terminal tab is a `ghostty_surface_t` created from it.
///
/// libghostty talks back to us through C function-pointer callbacks configured
/// on `ghostty_runtime_config_s`. C function pointers can't capture Swift
/// context, so:
///   - App-level callbacks (`wakeup`) route through `runtime.userdata`, which we
///     point at this instance.
///   - Surface-level actions (pwd/title changes) route through the surface's own
///     userdata, which we point at the owning `SurfaceView`.
final class GhosttyApp {
    // Implicitly-unwrapped so `self` is fully initialized (handle defaults to nil)
    // before we hand a pointer to `self` into the runtime config below.
    private(set) var handle: ghostty_app_t!
    private let config: GhosttyConfig

    init?() {
        let config = GhosttyConfig()
        self.config = config

        // GHOSTTY API: `ghostty_runtime_config_s` is the most version-sensitive
        // struct in the embedding API. Field set and callback signatures change
        // between releases — reconcile against the bundled ghostty.h if this
        // fails to compile.
        var runtime = ghostty_runtime_config_s()
        runtime.supports_selection_clipboard = false

        // Called (on an arbitrary thread) when libghostty has work queued and
        // needs the main thread to tick the app.
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { app.tick() }
        }

        // Single dispatch point for everything libghostty asks the host to do.
        runtime.action_cb = { _, target, action in
            GhosttyApp.handle(action: action, target: target)
        }

        // Minimal clipboard bridge. Reading is answered synchronously from the
        // general pasteboard; writing pushes onto it.
        runtime.read_clipboard_cb = { userdata, location, state in
            GhosttyApp.readClipboard(userdata: userdata, location: location, state: state)
        }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in
            // We don't gate paste behind a confirmation prompt.
        }
        runtime.write_clipboard_cb = { _, string, _, _ in
            guard let string else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(String(cString: string), forType: .string)
        }

        // Hand libghostty a pointer back to this instance; it's delivered to the
        // app-level callbacks (e.g. `wakeup_cb`) as their `userdata` argument.
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()

        guard let handle = ghostty_app_new(&runtime, config.handle) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        ghostty_app_free(handle)
    }

    /// Advance libghostty's event loop. Safe to call redundantly.
    func tick() {
        ghostty_app_tick(handle)
    }

    // MARK: - Action routing

    private static func handle(action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        // GHOSTTY API: action tags and their union payload field names track
        // ghostty.h. We only handle the ones this app cares about and let the
        // rest fall through as unhandled.
        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            if let view = surfaceView(from: target) {
                let pwd = String(cString: action.action.pwd.pwd)
                DispatchQueue.main.async { view.updatePwd(pwd) }
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            if let view = surfaceView(from: target) {
                let title = String(cString: action.action.set_title.title)
                DispatchQueue.main.async { view.updateTitle(title) }
            }
            return true

        default:
            return false
        }
    }

    /// Resolve a surface-targeted action back to the `SurfaceView` that owns the
    /// surface, via the surface's userdata pointer.
    private static func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        let contents = NSPasteboard.general.string(forType: .string) ?? ""
        // GHOSTTY API: the request is completed asynchronously by handing the
        // value back through the opaque `state` token.
        contents.withCString { ptr in
            ghostty_surface_complete_clipboard_request(state, ptr, false)
        }
    }
}
