// swift-tools-version:5.9
//
// Ground Control for macOS: a native window around the dashboard that the
// com.launchddash.server agent serves on 127.0.0.1:8787. No Xcode project —
// `macos/build.sh` assembles the .app bundle from what `swift build` produces.
import PackageDescription

let package = Package(
    name: "GroundControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GroundControl", targets: ["GroundControl"]),
        .executable(name: "GroundControlIcon", targets: ["GroundControlIcon"]),
    ],
    targets: [
        // Every decision the app makes (where a link opens, what the Dock badge says,
        // which launchctl command starts the server) lives here, Foundation only, so it
        // is unit-tested without a window, a web view or a live launchd.
        .target(name: "GroundControlCore"),
        .executableTarget(name: "GroundControl", dependencies: ["GroundControlCore"]),
        // Draws the app icon at build time. The icon is generated rather than committed:
        // a committed .icns would need a drift check, and PNG output is not guaranteed
        // byte-identical across macOS releases.
        .executableTarget(name: "GroundControlIcon"),
        .testTarget(name: "GroundControlCoreTests", dependencies: ["GroundControlCore"]),
        // The app target's one invisible contract: WebKit finds its delegate methods by
        // Objective-C selector, so a Swift signature that drifts from the SDK's compiles
        // fine and is simply never called.
        .testTarget(name: "GroundControlTests", dependencies: ["GroundControl", "GroundControlCore"]),
    ]
)
