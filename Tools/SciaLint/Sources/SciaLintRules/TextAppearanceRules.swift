import SwiftSyntax

extension Rule {
    // 文字の大きさを数字で決め打ちすると、端末の文字の大きさに従わない。書式（preferredFont）か、UIFontMetricsで大きさを変える文字で作る。
    // preferredFontのpointSizeから作った文字も、作った時点の大きさで止まるため、数字の幅を揃えるときはmonospacedDigitFont(forTextStyle:)で作る。
    // 枠の大きさが決まっていて文字を大きくできない場所（ステータスバーのように）だけ、拡大表示（Large Content Viewer）を付け、理由を書いてこの規則を外す
    static let fixedFontSize = Rule(
        id: "fixed_font_size",
        message: "文字の大きさを数字で決め打ちしない。書式で作るか、UIFontMetricsで大きさを変える。数字の幅を揃えるときはmonospacedDigitFont(forTextStyle:)で作る",
        appliesTo: isReleaseAppFile,
        find: { tree in
            tree.all(FunctionCallExprSyntax.self)
                .filter { $0.makesFixedSizeFont && !$0.isScaled }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )

    // 白を透かして控えめにした文字は、明るい画像の上で読みにくくなる。コントラストを上げる設定に応えるよう、dimmedWhiteText(alpha:)で作る
    static let dimmedWhiteText = Rule(
        id: "dimmed_white_text",
        message: "半透明の白い文字はdimmedWhiteText(alpha:)で作り、コントラストを上げる設定で濃くする",
        appliesTo: isReleaseAppFile,
        find: { tree in
            tree.all(FunctionCallExprSyntax.self)
                .filter { ($0.makesTranslucentWhite && $0.isUsedAsTextColor) || $0.dimsWhiteForeground }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )

    private static let isReleaseAppFile: @Sendable (String) -> Bool = { path in
        ["App/Sources/", "ShareExtension/", "Packages/TextKit2Label/Sources/"].contains { path.hasPrefix($0) } && !path.hasPrefix("App/Sources/Debug/")
    }
}

private extension FunctionCallExprSyntax {
    static let fixedSizeFontFunctions: Set = ["systemFont", "boldSystemFont", "italicSystemFont", "monospacedSystemFont", "monospacedDigitSystemFont"]

    /// `UIFont.systemFont(ofSize:)`やSwiftUIの`.system(size:)`のように、大きさを数字で渡して文字を作るか
    var makesFixedSizeFont: Bool {
        guard let name = calledName, let firstLabel = arguments.first?.label?.text else { return false }
        if Self.fixedSizeFontFunctions.contains(name) { return firstLabel == "ofSize" }
        return name == "system" && calledExpression.is(MemberAccessExprSyntax.self) && firstLabel == "size"
    }

    /// `UIFontMetrics(...).scaledFont(for:)`に渡して、端末の文字の大きさに合わせているか
    var isScaled: Bool {
        ancestorsInStatement.contains { node in
            guard let argument = node.as(LabeledExprSyntax.self), argument.label?.text == "for",
                  let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return false }
            return call.calledName == "scaledFont"
        }
    }

    /// `.white.withAlphaComponent(0.6)`や`Color.white.opacity(0.6)`のように、白を透かした色を作るか
    var makesTranslucentWhite: Bool {
        guard ["withAlphaComponent", "opacity"].contains(calledName),
              let base = calledExpression.as(MemberAccessExprSyntax.self)?.base else { return false }
        return base.identifierNames.contains("white")
    }

    static func isTextColorName(_ name: String) -> Bool {
        name.lowercased().hasSuffix("textcolor") || name == "foregroundColor" || name == "foregroundStyle"
    }

    /// 文字の色に使っているか。`textColor =`や`placeholderTextColor =`への代入、`textColor:`の引数、`.foregroundStyle(...)`と`.foregroundColor(...)`、
    /// 属性の`[.foregroundColor: ...]`と`addAttribute(.foregroundColor, value: ...)`を見る。いったん変数に入れてから渡す書き方は見分けない
    var isUsedAsTextColor: Bool {
        ancestorsInStatement.contains { node in
            if let argument = node.as(LabeledExprSyntax.self) {
                if let label = argument.label?.text, Self.isTextColorName(label) { return true }
                guard let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return false }
                if let name = call.calledName, Self.isTextColorName(name) { return true }
                // 属性のキーをほかの引数で渡す呼び出し
                return call.arguments.contains { other in
                    other.id != argument.id && other.expression.identifierNames.contains(where: Self.isTextColorName)
                }
            }
            if let element = node.as(DictionaryElementSyntax.self) {
                return element.key.identifierNames.contains(where: Self.isTextColorName)
            }
            if let sequence = node.as(SequenceExprSyntax.self) {
                let elements = Array(sequence.elements)
                guard elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) else { return false }
                return elements[0].identifierNames.last.map(Self.isTextColorName) ?? false
            }
            return false
        }
    }

    /// `Text(title).foregroundStyle(.white).opacity(0.6)`のように、白い文字にしたビューを透かしているか
    var dimsWhiteForeground: Bool {
        guard calledName == "opacity", var receiver = calledExpression.as(MemberAccessExprSyntax.self)?.base else { return false }
        while true {
            if let call = receiver.as(FunctionCallExprSyntax.self) {
                if let name = call.calledName, Self.isTextColorName(name),
                   call.arguments.contains(where: { $0.expression.identifierNames.contains("white") }) {
                    return true
                }
                receiver = call.calledExpression
            } else if let member = receiver.as(MemberAccessExprSyntax.self), let base = member.base {
                receiver = base
            } else {
                return false
            }
        }
    }
}
