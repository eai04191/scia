// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    // アプリと同じく、警告を止めるのはDebugのビルドの役目にする（project.ymlのReleaseの設定を参照）
    .treatAllWarnings(as: .error, .when(configuration: .debug)),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "SciaCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SciaCore", targets: ["SciaCore"]),
        // テストだけが使う、時間の長さに頼らずに順を作る道具。SciaCoreのテストとアプリのテストで共有する
        .library(name: "SciaTesting", targets: ["SciaTesting"]),
    ],
    targets: [
        .target(
            name: "SciaCore",
            resources: [.copy("Auth/Resources/known-servers.txt"), .copy("Compose/Resources/standard-emoji.json")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SciaTesting",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SciaCoreTests",
            dependencies: ["SciaCore", "SciaTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)
