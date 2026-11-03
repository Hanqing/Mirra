// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DisplayCam",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DisplayCam",
            path: "Sources/DisplayCam",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
