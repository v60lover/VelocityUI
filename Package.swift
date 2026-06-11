// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VelocityUI",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "VelocityUI",
            targets: ["VelocityUI"]
        )
    ],
    targets: [
        .target(
            name: "VelocityUI",
            path: "Sources/VelocityUI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VelocityUITests",
            dependencies: ["VelocityUI"],
            path: "Tests/VelocityUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
