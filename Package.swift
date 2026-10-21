// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OctoKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Octo", targets: ["OctoApp"]),
        .library(name: "OctoCore", targets: ["OctoCore"]),
        .library(name: "OctoAgents", targets: ["OctoAgents"]),
        .library(name: "OctoGit", targets: ["OctoGit"]),
        .library(name: "OctoReview", targets: ["OctoReview"]),
        .library(name: "OctoTerminal", targets: ["OctoTerminal"]),
        .library(name: "OctoGhostty", targets: ["OctoGhostty"])
    ],
    dependencies: [],
    targets: [
        .target(name: "OctoCore"),
        .target(name: "OctoGit", dependencies: ["OctoCore"]),
        .target(name: "OctoAgents", dependencies: ["OctoCore"]),
        .target(name: "OctoReview", dependencies: ["OctoCore"]),
        // Scripts/build-ghostty.sh creates this from Vendor/Ghostty.lock.json.
        .binaryTarget(name: "GhosttyKit", path: ".build/ghostty/GhosttyKit.xcframework"),
        .target(name: "OctoGhostty", dependencies: ["OctoCore", "GhosttyKit"], resources: [.copy("Resources/Runtime")],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon")]),
        .target(name: "OctoTerminal", dependencies: ["OctoCore", "OctoGhostty"]),
        .executableTarget(name: "OctoApp", dependencies: ["OctoCore", "OctoGit", "OctoAgents", "OctoReview", "OctoTerminal"]),
        .testTarget(name: "OctoAppTests", dependencies: ["OctoApp"]),
        .testTarget(name: "OctoReviewTests", dependencies: ["OctoReview"]),
        .testTarget(name: "OctoTerminalTests", dependencies: ["OctoTerminal"]),
        .testTarget(name: "OctoGhosttyTests", dependencies: ["OctoGhostty"]),
        .testTarget(name: "OctoCoreTests", dependencies: ["OctoCore"]),
        .testTarget(name: "OctoGitTests", dependencies: ["OctoGit"]),
        .testTarget(name: "OctoAgentsTests", dependencies: ["OctoAgents"])
    ],
    swiftLanguageModes: [.v5]
)
