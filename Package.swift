// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CSystemShims", path: "Sources/CSystemShims"),
        .target(name: "SwitchCore", dependencies: ["CSystemShims"]),
        .target(name: "SwitchUI", dependencies: ["SwitchCore"]),
        .executableTarget(name: "ClaudeSwitch", dependencies: ["SwitchCore", "SwitchUI"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"]),
        .testTarget(name: "SwitchUITests", dependencies: ["SwitchUI"]),
    ]
)
