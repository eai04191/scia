import SwiftSyntax

extension Rule {
    // 待ちの数で揃ったと読むと、同じ時計を使う別の待ちを数えて、起こしたい待ちが眠る前に時計を進めることがある。
    // 眠る前に進めた待ちはいつまでも起こされず、たまに上限まで固まる。別の待ちがあるかどうかは書き方から分からないので、数えて進める形そのものを止める
    static let advanceAfterSleeperCount = Rule(
        id: "advance_after_sleeper_count",
        message: "sleeperCountで待ってからadvanceしない。同じ時計を使う別の待ちを数えて、起こしたい待ちが眠る前に進めることがある。clock.advance(afterSleeping: 待ちの長さ)か、ほかの条件と一緒に待つならsleeperCount(remaining: 待ちの長さ)で、起こしたい待ちを長さで指す。長さの違う複数の待ちが揃うのを確かめるときだけ、理由を書いてこの規則を外す",
        appliesTo: { $0.hasPrefix("AppTests/") || $0.hasPrefix("Packages/SciaCore/Tests/") },
        find: { tree in
            tree.all(CodeBlockItemListSyntax.self)
                .flatMap(\.advancesAfterSleeperCountWait)
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

private extension CodeBlockItemListSyntax {
    /// 長さを指さずに`sleeperCount`で待った文のあと、次に`await`する文より前にある`advance(by:)`の呼び出し
    var advancesAfterSleeperCountWait: [FunctionCallExprSyntax] {
        let items = Array(self)
        return items.indices.filter { items[$0].waitsOnSleeperCount }.flatMap { index in
            items[(index + 1)...].prefix { !$0.containsAwait }.flatMap(\.advanceCalls)
        }
    }
}

private extension CodeBlockItemSyntax {
    var waitsOnSleeperCount: Bool {
        nodesInSameScope(FunctionCallExprSyntax.self)
            .filter { $0.calledName == "waitUntil" }
            .flatMap(\.conditionClosures)
            .contains { closure in
                let counts = closure.all(DeclReferenceExprSyntax.self).filter { $0.baseName.text == "sleeperCount" }.count
                let byRemaining = closure.all(FunctionCallExprSyntax.self).filter { $0.calledName == "sleeperCount" && $0.arguments.first?.label?.text == "remaining" }.count
                return counts > byRemaining
            }
    }

    /// `#expect(await ...)`は確かめるだけで、待ちが揃うのを待たないので、数えない
    var containsAwait: Bool {
        nodesInSameScope(AwaitExprSyntax.self).contains { await in
            !await.ancestors.contains { $0.is(MacroExpansionExprSyntax.self) }
        }
    }

    var advanceCalls: [FunctionCallExprSyntax] {
        nodesInSameScope(FunctionCallExprSyntax.self).filter { $0.calledName == "advance" && $0.arguments.first?.label?.text == "by" }
    }

    /// この文と同じ流れで実行される`type`のノード。閉包（`Task { ... }`など）や別の関数の中は、この文のあとに続けて走るとは限らないので含めない
    func nodesInSameScope<Node: SyntaxProtocol>(_ type: Node.Type) -> [Node] {
        all(type).filter { node in
            !node.ancestors.prefix { $0.id != id }.contains { $0.is(ClosureExprSyntax.self) || $0.is(FunctionDeclSyntax.self) }
        }
    }
}
