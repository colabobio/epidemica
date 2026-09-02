// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "epidemica_proximity_ios",
    // macOS is declared only so this package can share the wire codec, which is host-testable.
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "epidemica-proximity-ios", targets: ["epidemica_proximity_ios"])
    ],
    dependencies: [
        .package(url: "https://github.com/theheraldproject/herald-for-ios.git", exact: "2.2.0"),
        .package(path: "../../wire"),
    ],
    targets: [
        .target(
            name: "epidemica_proximity_ios",
            dependencies: [
                .product(name: "Herald", package: "herald-for-ios"),
                // Package identity for a path dependency is the directory name, not the manifest's
                // package name.
                .product(name: "ProximityWire", package: "wire"),
            ]
        )
    ]
)
