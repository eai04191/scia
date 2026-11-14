import SwiftSyntax

extension StringLiteralExprSyntax {
    /// 補間を除いた、文字列そのものの部分
    var literalText: String {
        segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    }

    /// 使う人に見えない文字列か。止める理由（preconditionFailureなど）とログに、引数としてそのまま渡すものは見せない。
    /// 閉包の中や、ほかの式に包んで渡したものは、使う人に見える文字列でありうるので見る
    var isOutsideUI: Bool {
        guard let argument = parent?.as(LabeledExprSyntax.self),
              let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
              let name = call.calledName else { return false }
        if ["precondition", "preconditionFailure", "fatalError", "assert", "assertionFailure"].contains(name) { return true }
        guard ["debug", "info", "notice", "error", "fault", "warning", "trace", "critical", "log"].contains(name),
              let receiver = call.calledExpression.as(MemberAccessExprSyntax.self)?.base else { return false }
        return Self.isLogger(receiver)
    }

    /// `logger`、`Self.logger`、`SciaLog.logger(category:)`のような、ログの受け手か
    private static func isLogger(_ expression: ExprSyntax) -> Bool {
        let name = expression.as(FunctionCallExprSyntax.self)?.calledName ?? expression.nameChainLast
        return name?.lowercased().hasSuffix("logger") ?? false
    }
}

extension SyntaxProtocol {
    /// `#if DEBUG`の枝の中か。デバッグ版だけに入るコードは、使う人に届かない
    var isInDebugOnlyBranch: Bool {
        var node = Syntax(self)
        while let parent = node.parent {
            if let clause = parent.as(IfConfigClauseSyntax.self), clause.condition?.trimmedDescription == "DEBUG" {
                return true
            }
            node = parent
        }
        return false
    }
}
