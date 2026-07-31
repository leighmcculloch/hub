import Termini

extension TerminiTerminalTheme {
    /// A light terminal theme tuned to the app's own light-mode chrome.
    ///
    /// The rest of the app in light mode is neutral: `.thinMaterial` sidebars
    /// and the default window background read as light gray, text is neutral
    /// near-black, and the only saturated colour is `Color.accentColor` — the
    /// system blue. The stock `.blueprint` preset is cool and blue-tinted
    /// (background `#F3F8FF`, foreground `#16324F`), so the terminal read as a
    /// differently-tinted surface dropped into a neutral window. This preset
    /// uses the same neutral gray surface and near-black text as the chrome,
    /// with the system blue reserved for the cursor and selection, so the
    /// terminal blends into the window as part of the same application.
    static let appLight = TerminiTerminalTheme(
        id: "app-light",
        name: "App Light",
        colorScheme: .light,
        background: .init(hex: 0xF2F2F2),
        foreground: .init(hex: 0x1D1D1F),
        cursor: .init(hex: 0x007AFF),
        selectionBackground: .init(hex: 0xC9DCFF),
        selectionForeground: .init(hex: 0x1D1D1F),
        ansiPalette: [
            // Normal — darkened green/yellow/cyan for legibility on light gray.
            .init(hex: 0x1D1D1F), .init(hex: 0xCC3B33), .init(hex: 0x1E8A33), .init(hex: 0xB7791F),
            .init(hex: 0x007AFF), .init(hex: 0xA63ACB), .init(hex: 0x1187A8), .init(hex: 0xD8D8DD),
            // Bright — the system accent shades at full strength.
            .init(hex: 0x6C6C70), .init(hex: 0xE5484D), .init(hex: 0x34C759), .init(hex: 0xE0A53A),
            .init(hex: 0x3D8CFF), .init(hex: 0xC77BDB), .init(hex: 0x59C6D9), .init(hex: 0xFFFFFF)
        ]
    )
}
