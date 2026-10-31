import SwiftSyntax

// ログに、ハンドル、本文、URL、応答の本文、サーバーの文言を公開扱いで出さない。info以上のログは違和感レポートに入り、ファイルアプリから取り出せる。
// privacyを書かない文字列も伏せられずに出るため、.privateか.sensitive以外はすべて止める。名前で見分けるので、決まり（docs/logging.md）で伏せるものの名前を使い始めたら足す。
// デバッグ用のコードはリリース版に入らないため対象外にする
extension Rule {
    static let logPrivateValue = Rule(
        id: "log_private_value",
        message: "ハンドル、本文、URL、応答の本文、サーバーの文言、localizedDescriptionをログに公開扱いで出さない。失敗はSciaLog.describe、URLはSciaLog.host(of:)で書き、追いたい値は.private(mask: .hash)にする（docs/logging.md）",
        appliesTo: { path in
            ["App/Sources/", "ShareExtension/", "Packages/SciaCore/Sources/SciaCore/"].contains { path.hasPrefix($0) }
                && !path.hasPrefix("App/Sources/Debug/")
        },
        find: { tree in
            logMessageSegments(in: tree).filter(LogPrivacy.reveals).map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

private enum LogPrivacy {
    static let levels: Set = ["debug", "info", "notice", "error", "fault", "warning", "trace", "critical", "log"]
    /// どこに出てきても伏せる名前
    static let sensitiveNames: Set = ["localizedDescription", "absoluteString", "acct", "username", "displayName", "serverMessage", "blurhash", "spoilerText"]
    /// そのものを出すと中身が出る名前。`url.host`のように、中の一部を出すのは止めない
    static let sensitiveValues: Set = ["error", "failure", "url", "text", "body", "content", "note"]
    /// 本文を指す名前。数や空かどうかを出すのは止めない
    static let bodyMembers: Set = ["text", "content", "note", "body"]
    static let harmlessBodyMembers: Set = ["count", "isEmpty"]
    static let urlParts: Set = ["path", "query", "lastPathComponent", "relativeString"]
    static let errorNames: Set = ["error", "failure"]

    /// 補間の中身が、公開扱いで出してはいけない値か
    static func reveals(_ segment: ExpressionSegmentSyntax) -> Bool {
        let arguments = segment.expressions
        let isHidden = arguments.contains { argument in
            argument.label?.text == "privacy" && ["private", "sensitive"].contains(argument.expression.leadingDotMemberName ?? "")
        }
        guard !isHidden, let value = arguments.first(where: { $0.label == nil })?.expression else { return false }
        if let name = value.nameChainLast, sensitiveValues.contains(name) { return true }
        return value.all(Syntax.self).contains { $0.isRevealing }
    }
}

private extension SyntaxProtocol {
    /// この構文そのものが、伏せる値を指しているか
    var isRevealing: Bool {
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            return LogPrivacy.sensitiveNames.contains(reference.baseName.text)
        }
        if let member = self.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if LogPrivacy.bodyMembers.contains(name) {
                return !member.isFollowed(byAnyOf: LogPrivacy.harmlessBodyMembers)
            }
            if LogPrivacy.urlParts.contains(name), member.base?.nameChainLast == "url" {
                return true
            }
            return false
        }
        if let call = self.as(FunctionCallExprSyntax.self), call.calledExpression.isStandardType("String"),
           let argument = call.arguments.first, argument.label?.text == "describing" {
            // `error as NSError`や`error.code`のように、失敗から始まる式は、続きによらず失敗の説明を含みうる
            return argument.expression.leadingNames.contains { LogPrivacy.errorNames.contains($0) }
        }
        return false
    }
}

private extension ExprSyntax {
    /// `a.b.c as T`の`a`、`b`、`c`のように、式の頭で`.`につながる名前
    var leadingNames: [String] {
        var names: [String] = []
        for token in tokens(viewMode: .sourceAccurate) {
            switch token.tokenKind {
            case .identifier(let name):
                names.append(name)
            case .period, .keyword(.self):
                continue
            default:
                return names
            }
        }
        return names
    }
}

private extension MemberAccessExprSyntax {
    /// `?`や`!`をはさんで、すぐ後ろに`names`のどれかが続くか
    func isFollowed(byAnyOf names: Set<String>) -> Bool {
        var node = Syntax(self)
        while let parent = node.parent, parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
            node = parent
        }
        guard let next = node.parent?.as(MemberAccessExprSyntax.self), next.base.map(Syntax.init) == node else { return false }
        return names.contains(next.declName.baseName.text)
    }
}

/// `logger.info("...")`のように、ログを書く呼び出しの最初の文字列の補間を集める
private func logMessageSegments(in tree: SourceFileSyntax) -> [ExpressionSegmentSyntax] {
    tree.all(FunctionCallExprSyntax.self).flatMap { call -> [ExpressionSegmentSyntax] in
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              LogPrivacy.levels.contains(member.declName.baseName.text),
              let first = call.arguments.first, first.label == nil,
              let literal = first.expression.as(StringLiteralExprSyntax.self) else { return [] }
        return literal.segments.compactMap { $0.as(ExpressionSegmentSyntax.self) }
    }
}
