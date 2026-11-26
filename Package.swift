// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ToolulaAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ToolulaAI", path: "Sources/ToolulaAI",
                          linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("AVFoundation"), .linkedFramework("WebKit"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices")]),
        .testTarget(name: "ToolulaAITests", dependencies: ["ToolulaAI"], path: "Tests/ToolulaAITests")
    ]
)
