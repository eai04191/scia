import SwiftSyntax

extension Rule {
    // 確認に書いた式の値だけでは、たまにしか落ちないテストの原因を落ちた回の記録から調べられない。落ちた時点の状態を添えるtraitを、どのsuiteにも付けさせる。
    static let suiteWithoutFailureState = Rule(
        id: "suite_without_failure_state",
        message: "アプリのテストのsuiteには@Suite(.failureState)を付け、落ちた時点の状態を失敗のメッセージに添えさせる",
        appliesTo: { $0.hasPrefix("AppTests/") },
        find: { tree in
            tree.all(FunctionDeclSyntax.self)
                .filter { $0.attributes.contains(named: "Test") }
                .compactMap { test -> AbsolutePosition? in
                    guard !test.attributes.hasFailureState else { return nil }
                    var outermost: (attributes: AttributeListSyntax, position: AbsolutePosition)?
                    var node = test.parent
                    while let current = node {
                        // 拡張に書いたテストは、拡張した型のsuiteに入る。@Suiteは拡張に付けられないので、型の宣言のほうで調べる。
                        // 型の宣言がほかのファイルにあり、そこにテストが1つもないと、付け忘れを見逃す。
                        if current.is(ExtensionDeclSyntax.self) { return nil }
                        if let attributes = current.asProtocol(WithAttributesSyntax.self)?.attributes, current.asProtocol(DeclGroupSyntax.self) != nil {
                            if attributes.hasFailureState { return nil }
                            outermost = (attributes, current.positionAfterSkippingLeadingTrivia)
                        }
                        node = current.parent
                    }
                    // suiteに入れずにファイルの直下に書いたテストは、そのテストに付けさせる。
                    return outermost?.position ?? test.positionAfterSkippingLeadingTrivia
                }
                .reduce(into: [AbsolutePosition]()) { positions, position in
                    if !positions.contains(position) { positions.append(position) }
                }
        }
    )
}

private extension AttributeListSyntax {
    func contains(named name: String) -> Bool {
        contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name }
    }

    /// `@Suite`か`@Test`の引数に`.failureState`があるか
    var hasFailureState: Bool {
        contains { element in
            guard let attribute = element.as(AttributeSyntax.self), ["Suite", "Test"].contains(attribute.attributeName.trimmedDescription),
                  let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)
            else { return false }
            return arguments.contains { $0.expression.leadingDotMemberName == "failureState" }
        }
    }
}
