import SwiftSyntax

extension ExprSyntax {
    /// `?`と`!`を外した式
    var unwrapped: ExprSyntax {
        if let optional = self.as(OptionalChainingExprSyntax.self) { return optional.expression.unwrapped }
        if let forced = self.as(ForceUnwrapExprSyntax.self) { return forced.expression.unwrapped }
        return self
    }

    /// `a.b?.c`のような名前だけをつないだ式なら、最後の名前を返す
    var nameChainLast: String? {
        let expression = unwrapped
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            guard member.base.map({ $0.nameChainLast != nil }) ?? true else { return nil }
            return member.declName.baseName.text
        }
        return nil
    }

    /// `.action`や`.action(...)`のように、型を省いた`.`で始まる式か
    var isLeadingDotMember: Bool {
        if let member = self.as(MemberAccessExprSyntax.self) { return member.base == nil }
        if let call = self.as(FunctionCallExprSyntax.self) { return call.calledExpression.isLeadingDotMember }
        return false
    }

    /// 標準の型`name`か、`Swift.String`や`_Concurrency.Task`のようにモジュールで修飾したものか
    func isStandardType(_ name: String) -> Bool {
        if let reference = self.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == name }
        if let member = self.as(MemberAccessExprSyntax.self), let module = member.base?.as(DeclReferenceExprSyntax.self) {
            return member.declName.baseName.text == name && ["Swift", "_Concurrency"].contains(module.baseName.text)
        }
        return false
    }

    /// `.name`か`.name(...)`なら、その名前を返す
    var leadingDotMemberName: String? {
        if let member = self.as(MemberAccessExprSyntax.self), member.base == nil { return member.declName.baseName.text }
        if let call = self.as(FunctionCallExprSyntax.self) { return call.calledExpression.leadingDotMemberName }
        return nil
    }
}

extension FunctionCallExprSyntax {
    /// `present(...)`や`view.present(...)`の`present`のような、呼び出す関数の名前
    var calledName: String? {
        if let reference = calledExpression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let member = calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return nil
    }

    func hasArgument(labeled label: String) -> Bool {
        arguments.contains { $0.label?.text == label }
    }
}

extension SyntaxProtocol {
    /// 親をたどった構文。近いものから並ぶ
    var ancestors: [Syntax] {
        var result: [Syntax] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    /// 同じ文の中で親をたどった構文。閉包の中の文から、閉包を渡した呼び出しへは出ない
    var ancestorsInStatement: [Syntax] {
        Array(ancestors.prefix { !$0.is(CodeBlockItemSyntax.self) && !$0.is(ClosureExprSyntax.self) })
    }

    /// 識別子の名前を、出てくる順に集める
    var identifierNames: [String] {
        tokens(viewMode: .sourceAccurate).compactMap { token in
            if case .identifier(let name) = token.tokenKind { name } else { nil }
        }
    }

    /// 子孫のうち、`type`の構文を出てくる順に集める
    func all<Node: SyntaxProtocol>(_ type: Node.Type) -> [Node] {
        let collector = NodeCollector<Node>()
        collector.walk(self)
        return collector.nodes
    }
}

private final class NodeCollector<Node: SyntaxProtocol>: SyntaxAnyVisitor {
    private(set) var nodes: [Node] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let node = node.as(Node.self) {
            nodes.append(node)
        }
        return .visitChildren
    }
}
