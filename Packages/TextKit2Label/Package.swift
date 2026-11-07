// swift-tools-version: 6.2
import PackageDescription

// Sciaに依存しない、TextKit 2で文字を並べて描くラベル（TextKitLabel）。アプリが使う。Sciaの型を使わないことを、パッケージを分けてコンパイラーで守る。
// UIKitに依存するため、テストはmacOSの`swift test`では走らせず、アプリのスキームに並べてシミュレーターで走らせる（project.ymlのschemesを参照）
let swiftSettings: [SwiftSetting] = [
    // SciaCoreと同じく、警告を止めるのはDebugのビルドの役目にする（project.ymlのReleaseの設定を参照）
    .treatAllWarnings(as: .error, .when(configuration: .debug)),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "TextKit2Label",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "TextKit2Label", targets: ["TextKit2Label"]),
    ],
    targets: [
        .target(
            name: "TextKit2Label",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TextKit2LabelTests",
            dependencies: ["TextKit2Label"],
            swiftSettings: swiftSettings
        ),
    ]
)
