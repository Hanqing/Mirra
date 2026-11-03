// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Mirra",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Auto-update from GitHub Releases (appcast hosted on GitHub Pages).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Mirra",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Mirra",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
