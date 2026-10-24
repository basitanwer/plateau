// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Plateau",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "Shared", dependencies: ["CSMC"]),
        .executableTarget(name: "Helper", dependencies: ["Shared"]),
        .executableTarget(name: "Plateau", dependencies: ["Shared"]),
        .testTarget(name: "SharedTests", dependencies: ["Shared"]),
    ]
)
