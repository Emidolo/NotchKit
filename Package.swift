// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchKit"),
        .testTarget(name: "NotchKitTests", dependencies: ["NotchKit"]),
    ]
)
