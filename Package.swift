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
        .library(name: "OctoTerminal", targets: ["OctoTerminal"])
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "b7f888e3baf8585ea9d590ab1a45b49475e00d1c")
    ],
    targets: [
        .target(name: "OctoCore"),
        .target(name: "OctoGit", dependencies: ["OctoCore"]),
        .target(name: "OctoAgents", dependencies: ["OctoCore"]),
        .target(name: "OctoReview", dependencies: ["OctoCore"]),
        .target(name: "OctoTerminal", dependencies: ["OctoCore", .product(name: "GhosttyTerminal", package: "libghostty-spm")]),
        .executableTarget(name: "OctoApp", dependencies: ["OctoCore", "OctoGit", "OctoAgents", "OctoReview", "OctoTerminal"]),
        .testTarget(name: "OctoAppTests", dependencies: ["OctoApp"]),
        .testTarget(name: "OctoReviewTests", dependencies: ["OctoReview"]),
        .testTarget(name: "OctoCoreTests", dependencies: ["OctoCore"]),
        .testTarget(name: "OctoGitTests", dependencies: ["OctoGit"]),
        .testTarget(name: "OctoAgentsTests", dependencies: ["OctoAgents"])
    ],
    swiftLanguageModes: [.v5]
)
