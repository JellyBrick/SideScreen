// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AOATest",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AOATest",
            targets: ["AOATest"])
    ],
    targets: [
        .executableTarget(
            name: "AOATest",
            dependencies: [],
            path: "Sources")
    ]
)
