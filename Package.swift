// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Cpuline",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Cpuline", targets: ["Cpuline"])
    ],
    targets: [
        .executableTarget(
            name: "Cpuline",
            path: "Sources/Cpuline"
        ),
        .testTarget(
            name: "CpulineTests",
            dependencies: ["Cpuline"]
        )
    ]
)