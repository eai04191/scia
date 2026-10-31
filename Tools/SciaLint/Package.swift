// swift-tools-version: 6.2
import PackageDescription

// SwiftLintの独自規則は正規表現でしか書けず、引数を複数行に分けた書き方や、括弧の入れ子を見分けられない。
// 呼び出しや文字列の補間の形で決まる規則は、ここで構文木を読んで調べる。型は分からないので、名前で見分けるところは正規表現の規則と変わらない
let package = Package(
    name: "SciaLint",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "scia-lint", targets: ["scia-lint"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .target(
            name: "SciaLintRules",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "scia-lint",
            dependencies: ["SciaLintRules"]
        ),
        .testTarget(
            name: "SciaLintRulesTests",
            dependencies: ["SciaLintRules"]
        ),
    ]
)
