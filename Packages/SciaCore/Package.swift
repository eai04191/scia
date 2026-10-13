// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "SciaCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SciaCore", targets: ["SciaCore"]),
    ],
    targets: [
        .target(name: "SciaCore", swiftSettings: swiftSettings),
        .testTarget(
            name: "SciaCoreTests",
            dependencies: ["SciaCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)
