import AppKit

/// The dashboard's own tokens (`:root` in the page's stylesheet), so the native parts —
/// the title bar, the offline screen, the area behind an overscroll — match the page.
enum Palette {
    static let background = rgb(0x0f1115) // --bg
    static let text = rgb(0xe7e9ee) // --text
    static let secondaryText = rgb(0xaeb4c0) // --text-3
    static let muted = rgb(0x8b909c) // --muted
    static let warn = rgb(0xf0b86e) // --warn

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
    }
}

extension Bundle {
    /// `CFBundleShortVersionString`, or "dev" when run with `swift run` (no bundle).
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
