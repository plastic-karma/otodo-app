// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OTodoCore",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "OTodoCore", targets: ["OTodoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(
            name: "OTodoCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "OTodoCoreTests",
            dependencies: ["OTodoCore"],
            path: "Tests/OTodoCoreTests"
        ),
    ]
)
