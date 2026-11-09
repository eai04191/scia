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
    dependencies: [
        .package(path: "../MemoryCache"),
    ],
    targets: [
        // シグナルハンドラーから触るクラッシュの記録。docs/crash-quarantine.md
        .target(name: "CCrashMark"),
        .target(name: "CCrashMarkTesting", dependencies: ["CCrashMark"]),
        .target(
            name: "SciaCore",
            dependencies: ["MemoryCache", "CCrashMark"],
            resources: [.copy("Auth/Resources/known-servers.txt"), .copy("Compose/Resources/standard-emoji.json"), .copy("Settings/Resources/menu-defaults.json")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SciaTesting",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SciaCoreTests",
            dependencies: ["SciaCore", "SciaTesting", "CCrashMarkTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)
