// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "BODragScroll",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(name: "BODragScroll", targets: ["BODragScroll"])
    ],
    targets: [
        .target(
            name: "BODragScroll",
            path: "Sources/BODragScroll"
        ),
        .testTarget(
            name: "BODragScrollTests",
            dependencies: ["BODragScroll"],
            path: "Tests/BODragScrollTests"
        )
    ]
)
