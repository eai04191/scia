import SwiftSyntax

// 使う人に見える文言は、SciaCoreに置く。iOSのアプリに書くと、SciaCoreだけを使う別のUI（AppKitのMac版など）が同じ文言を出せず、UIごとに言い回しがずれる。
// 日本語の文字を含む文字列リテラルを、使う人に見える文言として見つける。使う人に見えない文字列（preconditionFailureなどの理由、ログ）と、
// デバッグ版だけに入るもの（App/Sources/Debug、違和感レポート、`#if DEBUG`の枝）、`Config/app-info.json`から書き出したファイルは見ない
extension Rule {
    static let userTextOutsideCore = Rule(
        id: "user_text_outside_core",
        message: "使う人に見える文言はSciaCoreに置き、ここでは読むだけにする。値を埋める文言は、埋める値を受け取って文を丸ごと返す関数にする（AGENTS.mdの「文言」）",
        appliesTo: { path in
            path.hasPrefix("App/Sources/")
                && !["App/Sources/Debug/", "App/Sources/DiscomfortReport/"].contains { path.hasPrefix($0) }
                && !path.hasSuffix(".generated.swift")
        },
        find: { tree in
            tree.all(StringLiteralExprSyntax.self)
                .filter { $0.containsJapanese && !$0.isOutsideUI && !$0.isInDebugOnlyBranch }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

extension StringLiteralExprSyntax {
    /// ひらがな、カタカナ、漢字、日本語の句読点（「、」「。」「・」など）、全角の記号（「（」「：」など）のどれかを含むか。
    /// 句読点や全角の記号だけでも、値を日本語の文につなげる書き方（`"\(名前)、\(ハンドル)"`）になるので見る
    var containsJapanese: Bool {
        literalText.unicodeScalars.contains { scalar in
            [0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF01...0xFF60].contains { $0.contains(scalar.value) }
        }
    }
}
