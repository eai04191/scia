import SwiftSyntax

extension Rule {
    // 出る途中の画面の上に確認やシートを出すと、UIKitは出さずに捨てる。出した直後の待ちは負荷のかかった実行では出し終える前に抜けるため、ときどきだけ落ちる
    static let presentWithoutWaiting = Rule(
        id: "present_without_waiting",
        message: "テストで画面を出すときは、presentForTestingで出し終えるまで待つ。出る途中を確かめるときだけ、理由を書いてこの規則を外す",
        appliesTo: { $0.hasPrefix("AppTests/") },
        find: { tree in
            tree.all(FunctionCallExprSyntax.self)
                .filter { $0.calledName == "present" && $0.hasArgument(labeled: "animated") }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}
