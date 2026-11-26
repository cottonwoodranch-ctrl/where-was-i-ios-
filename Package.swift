// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhereWasICore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "WhereWasICore", targets: ["WhereWasICore"])
    ],
    targets: [
        .target(
            name: "WhereWasICore",
            path: "Sources/WhereWasICore"
        ),
        .testTarget(
            name: "WhereWasICoreTests",
            dependencies: ["WhereWasICore"],
            path: "Tests/WhereWasICoreTests"
        )
    ]
)
