// swift-tools-version: 6.2
import PackageDescription

// Sciaに依存しない、メモリに持つキャッシュ。SciaCoreとアプリが使う。SciaCoreに依存しないことを、パッケージを分けてコンパイラーで守る
let swiftSettings: [SwiftSetting] = [
    // SciaCoreと同じく、警告を止めるのはDebugのビルドの役目にする（project.ymlのReleaseの設定を参照）
    .treatAllWarnings(as: .error, .when(configuration: .debug)),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "MemoryCache",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MemoryCache", targets: ["MemoryCache"]),
    ],
    targets: [
        .target(
            name: "MemoryCache",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MemoryCacheTests",
            dependencies: ["MemoryCache"],
            swiftSettings: swiftSettings
        ),
    ]
)
