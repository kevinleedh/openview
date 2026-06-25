// swift-tools-version: 6.0
import PackageDescription

// Padafa — a Mac PDF AI viewer. Pure-AppKit, NSDocument-based rewrite (see files/migration_appkit.md).
// macOS 14 floor per decision #10 (mlx-swift declares .macOS(.v14)).
// Built with `swift build` + make_app.sh (no Xcode): Command-Line-Tools-only installs lack
// xcodebuild and XCTest, so there is no test target — engine logic is validated by the ported
// benchmark harnesses (benchmark/*.py) and CLI self-tests, exactly as in the proven prior build.
let package = Package(
    name: "Padafa",
    platforms: [.macOS(.v14)],
    targets: [
        // Port-as-is engine logic (UI-independent): coordinate y-flip adapter + sidecar IPC client.
        // Swift 5 language mode (matches the app target): the sidecar client drives Foundation pipe
        // readabilityHandlers (@Sendable closures) that capture the client's lock-guarded buffers —
        // correct under a serial protocol, but strict Swift 6 concurrency rejects the self-capture.
        .target(name: "PadafaKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The app shell — pure AppKit. Swift 5 language mode eases AppKit/PDFKit interop (matches the
        // prior build's setting), keeping the focus on native behavior over strict-concurrency churn.
        .executableTarget(
            name: "Padafa",
            dependencies: ["PadafaKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Coordinate-PoC driver (gated, headless): selftest | gen | truth | convert | render | e2e.
        // Drives the SAME live PadafaKit.CoordinateAdapter the app uses, so the #7 gate measures the
        // shipping transform — not a copy. Ported from the prior build (import CoordPoC → PadafaKit).
        .executableTarget(
            name: "coordcli",
            dependencies: ["PadafaKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
