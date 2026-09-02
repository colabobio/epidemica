// swift-tools-version: 5.9
import PackageDescription

/// The wire codec, kept in its own package with no dependency on Flutter or Herald.
///
/// That isolation is the point: `swift test` runs here in seconds with no Xcode project, no
/// simulator and no app, which is what makes the Swift side of the wire format as cheap to check
/// as the Kotlin side.
///
/// It sits *inside* the plugin package rather than beside it because Flutter symlinks the plugin
/// directory into an app's ephemeral Packages, and SPM resolves a relative dependency against the
/// symlink's location. A sibling package escapes the staged tree, and Xcode fails to resolve it
/// with an error naming a directory nobody wrote.
let package = Package(
    name: "ProximityWire",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "ProximityWire", targets: ["ProximityWire"])
    ],
    targets: [
        .target(name: "ProximityWire"),
        .testTarget(name: "ProximityWireTests", dependencies: ["ProximityWire"]),
    ]
)
