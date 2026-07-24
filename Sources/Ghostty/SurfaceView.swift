import AppKit
import GhosttyKit

/// A layer-backed AppKit view that hosts one libghostty terminal surface.
///
/// libghostty renders into this view's layer with Metal on its own thread; our
/// job is to (1) create the surface bound to this view, (2) keep it sized and
/// scaled, (3) forward keyboard/mouse input, and (4) drive redraws via a display
/// link. Surface actions that concern this view (pwd/title changes) arrive back
/// through `GhosttyApp`, which calls `updatePwd`/`updateTitle`.
final class SurfaceView: NSView {
    private let app: GhosttyApp
    private var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?

    /// Called on the main thread when the shell's working directory changes.
    var onPwdChange: ((String) -> Void)?
    /// Called on the main thread when the terminal title changes.
    var onTitleChange: ((String) -> Void)?

    init(app: GhosttyApp) {
        self.app = app
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        postsFrameChangedNotifications = true

        createSurface()
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        stopDisplayLink()
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface lifecycle

    private func createSurface() {
        // GHOSTTY API: surface config is created with defaults, then we fill in
        // the platform view pointer, scale and userdata before creating.
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = window?.backingScaleFactor ?? 2.0
        // Userdata lets action callbacks route back to this exact view.
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        surface = ghostty_surface_new(app.handle, &config)
    }

    private var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2.0
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    // MARK: - Sizing & scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let size = pixelSize
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(pixelSize.width), UInt32(pixelSize.height))
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: - Redraw loop

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userdata in
            let view = Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
            if let surface = view.surface {
                ghostty_surface_draw(surface)
            }
            return kCVReturnSuccess
        }, opaque)
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
    }

    // MARK: - Model callbacks (called from GhosttyApp on the main thread)

    func updatePwd(_ pwd: String) { onPwdChange?(pwd) }
    func updateTitle(_ title: String) { onTitleChange?(title) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
        // Let AppKit turn the event into inserted text / IME (routed to insertText).
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        // GHOSTTY API: `ghostty_input_key_s` carries the action, modifiers and
        // the platform keycode. Full text/keymap translation is richer in
        // Ghostty's own app; this covers control keys and lets `insertText`
        // handle printable/IME text.
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = translateMods(event.modifierFlags)
        key.keycode = UInt32(event.keyCode)
        ghostty_surface_key(surface, key)
    }

    private func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }

    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods(event)
        )
    }

    private func sendMouseButton(
        _ event: NSEvent,
        _ action: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, action, button, translateMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let local = convert(event.locationInWindow, from: nil)
        // Flip to top-left origin in pixels, which is what libghostty expects.
        let x = local.x * scale
        let y = (bounds.height - local.y) * scale
        ghostty_surface_mouse_pos(surface, x, y, translateMods(event.modifierFlags))
    }

    private func scrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        // GHOSTTY API: scroll mods is a small bitfield (precision / momentum).
        // We report precision scrolling for trackpads.
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods = 1 }
        return ghostty_input_scroll_mods_t(mods)
    }

    // MARK: - Tracking areas (so mouseMoved fires)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}

// MARK: - Text input

extension SurfaceView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
        }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
