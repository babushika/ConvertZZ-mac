// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConvertZZ",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ConvertZZ", targets: ["ConvertZZ"]),
        .library(name: "ConvertZZCore", targets: ["ConvertZZCore"]),
    ],
    targets: [
        .target(name: "ConvertZZCore"),
        .executableTarget(name: "ConvertZZ", dependencies: ["ConvertZZCore"]),
        .testTarget(name: "ConvertZZCoreTests", dependencies: ["ConvertZZCore"]),
    ]
)
