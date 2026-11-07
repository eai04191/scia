import SwiftSyntax

// 使う人に見える文言は、iOSの日本語UIの標準の言い回し（設定アプリ、メール、Safariなどの表記）に倣う。前に直した言い回しが戻らないよう、文字列リテラルで見つけたら止める。
// 並べた語しか見つけないので、ここにない言い回しはAGENTS.mdの「文言」の方針で判断する。
// 使う人に見えない文字列（preconditionFailureなどの理由、ログ）は見ない。デバッグ版だけの画面（App/Sources/Debug、違和感レポート）と、チューニングの見出しも見ない
extension Rule {
    static let iosWording = Rule(
        id: "ios_wording",
        message: "iOSの標準の言い回しにする。既定→デフォルト、捨てる→破棄、消す→削除か消去、止める→中止、端末→デバイスかストレージ、足す→追加、出す・見せる→表示、やり直してください→もう一度お試しください、起動し直す→再起動、押すと→タップすると（VoiceOverのヒントでは操作を言わず、起きることだけを書く）",
        appliesTo: { path in
            ["App/Sources/", "ShareExtension/", "Packages/SciaCore/Sources/SciaCore/"].contains { path.hasPrefix($0) }
                && !["App/Sources/Debug/", "App/Sources/DiscomfortReport/", "Packages/SciaCore/Sources/SciaCore/Tuning/"].contains { path.hasPrefix($0) }
        },
        find: { tree in
            tree.all(StringLiteralExprSyntax.self)
                .filter { IOSWording.containsAvoided($0.literalText) && !$0.isOutsideUI }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

enum IOSWording {
    /// 止める言い回し。`allowedPrefixes`は、前に付くと別の語になるもの（「取り消す」の「取り」、「不足して」の「不」など）
    static let avoided: [(phrase: String, allowedPrefixes: [String])] = [
        ("既定", []),
        ("捨て", []),
        ("端末", []),
        ("やり直してください", []),
        ("起動し直", []),
        ("足す", addPrefixes),
        ("足して", addPrefixes),
        ("足しま", addPrefixes),
        ("見せる", []),
        ("見せま", []),
        ("出さない", []),
        ("を出す", []),
        ("を出しま", []),
        ("消す", ["取り"]),
        ("消して", ["取り"]),
        ("消しま", ["取り"]),
        ("消せ", ["取り"]),
        ("消えます", []),
        ("止める", []),
        ("止めま", []),
        ("押すと", []),
    ]

    /// 「足」で終わる、追加の意味でない語の頭
    private static let addPrefixes = ["打ち", "不", "補", "満"]

    static func containsAvoided(_ text: String) -> Bool {
        avoided.contains { entry in
            entry.allowedPrefixes.reduce(text) { $0.replacingOccurrences(of: $1 + entry.phrase, with: "") }.contains(entry.phrase)
        }
    }
}

private extension String {
    /// Foundationに頼らずに、`target`をすべて`replacement`に替える
    func replacingOccurrences(of target: String, with replacement: String) -> String {
        split(separator: target, omittingEmptySubsequences: false).joined(separator: replacement)
    }
}

private extension StringLiteralExprSyntax {
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
