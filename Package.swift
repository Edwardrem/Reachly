// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReachlyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReachlyCore", targets: ["ReachlyCore"]),
        .library(name: "ReachlySSH", targets: ["ReachlySSH"]),
        .library(name: "ReachlyTerminal", targets: ["ReachlyTerminal"]),
        .library(name: "ReachlyAgent", targets: ["ReachlyAgent"]),
        .executable(name: "reachly-mcp", targets: ["reachly-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.2"),
    ],
    targets: [
        .target(name: "ReachlyCore"),
        .target(
            name: "ReachlySSH",
            dependencies: [
                "ReachlyCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(
            name: "ReachlyTerminal",
            dependencies: [
                "ReachlyCore",
                "ReachlySSH",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "ReachlyAgent",
            dependencies: [
                "ReachlyCore",
                "ReachlySSH",
                "ReachlyTerminal",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "reachly-mcp"),
        // A scripted ACP agent the tests launch as a process in place of a real one such as Qoder.
        .executableTarget(name: "fake-acp-agent", path: "Tests/FakeACPAgent"),
        .testTarget(name: "ReachlyCoreTests", dependencies: ["ReachlyCore"]),
        .testTarget(name: "ReachlySSHTests", dependencies: ["ReachlySSH", "ReachlyCore"]),
        .testTarget(name: "ReachlyTerminalTests", dependencies: ["ReachlyTerminal", "ReachlySSH", "ReachlyCore"]),
        .testTarget(name: "ReachlyAgentTests", dependencies: ["ReachlyAgent", "ReachlyTerminal", "ReachlySSH", "ReachlyCore", "fake-acp-agent"]),
    ]
)
