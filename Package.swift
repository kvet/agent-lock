// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-lock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "agent-lock", targets: ["agent-lock"]),
    ],
    targets: [
        .target(name: "AgentLockCore"),
        .executableTarget(name: "agent-lock", dependencies: ["AgentLockCore"]),
        // Depends on the executable so `swift test` builds the binary the integration tests spawn.
        .testTarget(name: "AgentLockTests", dependencies: ["AgentLockCore", "agent-lock"]),
    ]
)
