// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PSController",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PSController", targets: ["PSController"])
    ],
    targets: [
        .executableTarget(
            name: "PSController",
            path: "Sources/PSController"
        ),
        .testTarget(
            name: "PSControllerTests",
            dependencies: ["PSController"],
            path: "Tests/PSControllerTests"
        )
    ]
)
