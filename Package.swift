// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallNotes",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "CallNotes",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/CallNotes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
