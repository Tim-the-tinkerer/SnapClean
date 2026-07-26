// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapClean",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SnapClean", targets: ["SnapClean"]),
    ],
    targets: [
        .executableTarget(
            name: "SnapClean",
            path: "Sources/SnapClean"
        ),
    ]
)
