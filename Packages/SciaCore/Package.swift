// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SciaCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SciaCore", targets: ["SciaCore"]),
    ],
    targets: [
        .target(name: "SciaCore"),
        .testTarget(
            name: "SciaCoreTests",
            dependencies: ["SciaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
