// swift-tools-version: 6.2
import PackageDescription

// 長押しのメニューの既定の並びを編集するページ（editor.html）に、SciaCoreの項目の名前と今の既定の並びを入れて書き出す
let package = Package(
    name: "MenuEditor",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/SciaCore"),
    ],
    targets: [
        .executableTarget(
            name: "menu-editor",
            dependencies: [.product(name: "SciaCore", package: "SciaCore")]
        ),
    ]
)
