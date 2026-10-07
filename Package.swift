// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RobotsTxt",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // Core: parse, isAllowed, matchingRule, crawlDelay, statusPolicy. No Foundation.
        .library(name: "RobotsTxt", targets: ["RobotsTxt"]),
    ],
    targets: [
        .target(name: "RobotsTxt"),
        .testTarget(name: "RobotsTxtTests", dependencies: ["RobotsTxt"]),

        // Tooling: conformance runner, mutation fuzzer.
        .executableTarget(name: "robotstxt-conformance", dependencies: ["RobotsTxt"]),
        .executableTarget(name: "robotstxt-fuzz", dependencies: ["RobotsTxt"]),
    ]
)
