import SwiftSyntax

extension Rule {
    // waitUntilは条件を間をおいて確かめるので、確かめる間に件数が待つ数を飛び越えると、一致しないまま上限まで固まる。
    // 余分に1回読み込むような不具合も、何回になったかを残さずに固まるだけになる。
    // `.count`の名前で見分けるので、`sleeperCount`のように増えも減りもする今の数は対象にしない
    static let exactCountWait = Rule(
        id: "exact_count_wait",
        message: "waitUntilの条件で件数を==で待たない。増えていく件数は>=で待ち、待ったあと#expectで件数を確かめる。減っていく件数は<=で待つ。ちょうどその件数の間だけ起きることを確かめるときだけ、理由を書いてこの規則を外す",
        appliesTo: { $0.hasPrefix("AppTests/") || $0.hasPrefix("Packages/SciaCore/Tests/") },
        find: { tree in
            tree.all(FunctionCallExprSyntax.self)
                .filter { $0.calledName == "waitUntil" }
                .flatMap(\.conditionClosures)
                .flatMap { closure in
                    closure.all(SequenceExprSyntax.self)
                        .filter { $0.nearestClosure?.id == closure.id }
                        .flatMap(\.countEqualityOperators)
                }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

private extension FunctionCallExprSyntax {
    /// 待つ条件を渡した閉包。失敗に添える状態（`state:`）は条件ではないので除く
    var conditionClosures: [ClosureExprSyntax] {
        let arguments = arguments.filter { $0.label?.text != "state" }.compactMap { $0.expression.as(ClosureExprSyntax.self) }
        return arguments + [trailingClosure].compactMap(\.self) + additionalTrailingClosures.map(\.closure)
    }
}

private extension SyntaxProtocol {
    /// いちばん近い閉包。`filter { $0.count == 2 }`のように、条件の中で渡した閉包の比較を、待つ条件と分けるのに使う
    var nearestClosure: ClosureExprSyntax? {
        ancestors.lazy.compactMap { $0.as(ClosureExprSyntax.self) }.first
    }
}

private extension SequenceExprSyntax {
    /// `==`のうち、どちらかの辺がそのまま`.count`のもの。演算子はまだ優先順位で組まれていないので、
    /// `==`より弱いか同じ強さの演算子（比較と論理）で区切った前後を、それぞれの辺とみなす。`??`は比較より強いので、`x?.count ?? 0`は1つの辺になる
    var countEqualityOperators: [BinaryOperatorExprSyntax] {
        let elements = Array(self.elements)
        func side(_ range: some Sequence<Int>) -> [ExprSyntax] {
            Array(range.lazy.map { elements[$0] }.prefix { !$0.isComparisonOrLogicalOperator })
        }
        return elements.indices.compactMap { index in
            guard let binary = elements[index].as(BinaryOperatorExprSyntax.self), binary.operator.text == "==" else { return nil }
            let sides = side((0..<index).reversed()) + side((index + 1)..<elements.count)
            return sides.contains(where: \.isCountOperand) ? binary : nil
        }
    }
}

private extension ExprSyntax {
    /// `==`より弱いか同じ強さの演算子（比較と論理）か。これで区切った前後が`==`の辺になり、これを含む式の値は件数ではなく真偽になる
    var isComparisonOrLogicalOperator: Bool {
        let operators: Set<String> = ["==", "!=", "<", ">", "<=", ">=", "===", "!==", "&&", "||"]
        return self.as(BinaryOperatorExprSyntax.self).map { operators.contains($0.operator.text) } ?? false
    }

    /// `.count`か、括弧の中や`x?.count ?? 0`、`await x.count`のように、演算の項に`.count`を含むもの。
    /// `(x.count >= 2) == true`の括弧の中のように、比較や論理の演算の結果は件数ではないので含めない
    var isCountOperand: Bool {
        if let awaited = self.as(AwaitExprSyntax.self) { return awaited.expression.isCountOperand }
        if let tried = self.as(TryExprSyntax.self) { return tried.expression.isCountOperand }
        let expression = unwrapped
        if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text == "count" }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
            return element.expression.isCountOperand
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            return !sequence.elements.contains(where: \.isComparisonOrLogicalOperator) && sequence.elements.contains(where: \.isCountOperand)
        }
        return false
    }
}
