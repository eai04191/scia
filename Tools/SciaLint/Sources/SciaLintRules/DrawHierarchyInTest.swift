import SwiftSyntax

extension Rule {
    // drawHierarchyは1回に20〜40ミリ秒かかり、動きのコマごとに描くとテストが数秒延びる。描く回数を限るHierarchyDrawerを通させる。
    static let drawHierarchyInTest = Rule(
        id: "draw_hierarchy_in_test",
        message: "テストで画面を画像に描くときは、drawHierarchyを直接呼ばず、描く回数を限るHierarchyDrawerで描く",
        appliesTo: { $0.hasPrefix("AppTests/") && $0 != "AppTests/Support/HierarchyDrawer.swift" },
        find: { tree in
            tree.all(MemberAccessExprSyntax.self)
                .filter { $0.declName.baseName.text == "drawHierarchy" }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}
