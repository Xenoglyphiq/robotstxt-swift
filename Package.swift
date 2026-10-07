// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RobotsTxt",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Core: parse, isAllowed, matchingRule, crawlDelay, statusPolicy. No Foundation.
        .library(name: "RobotsTxt", targets: ["RobotsTxt"]),
        // io: fetch over a Transport, with a URLSession transport.
        .library(name: "RobotsTxtIO", targets: ["RobotsTxtIO"]),
    ],
    targets: [
        .target(name: "RobotsTxt"),
        .target(name: "RobotsTxtIO", dependencies: ["RobotsTxt"]),
        .testTarget(name: "RobotsTxtTests", dependencies: ["RobotsTxt", "RobotsTxtIO"]),

        // Tooling: conformance runner, mutation fuzzer.
        .executableTarget(name: "robotstxt-conformance", dependencies: ["RobotsTxt", "RobotsTxtIO"]),
        .executableTarget(name: "robotstxt-fuzz", dependencies: ["RobotsTxt", "RobotsTxtIO"]),
    ]
)
