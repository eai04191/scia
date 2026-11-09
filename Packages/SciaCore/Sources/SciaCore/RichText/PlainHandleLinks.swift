import Foundation

/// 文字のままの`@user@domain`を、ハンドルで探すリンクにする。
/// サーバーは、自分が知らない相手のハンドルをリンクにせず文字のまま返すため、プロフィールの文章に書かれた別のアカウントを開けない。決まりはdocs/profile.mdの「プロフィールを開くまで」にある。
///
/// ユーザー名の形はMastodonの`Account::USERNAME_RE`に合わせる。`Account::MENTION_RE`と違い、日本語の文字のすぐ後ろの`@`も読む。
/// サーバー名はASCIIだけを読む。後ろに続く日本語の文をサーバー名に含めないため。`@alice@例え.テスト`のようにUnicodeで書かれたサーバーは、リンクにならず文字のまま残る。
/// xn--の形で書いてあれば読める。
/// サーバー名の続きがあるのに短く切ると別のサーバーを指すので、続きがあれば（`@`や、`.`の後ろの文字）リンクにしない。
enum PlainHandleLinks {
    private static let pattern: NSRegularExpression = {
        let label = "[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
        let source = "(?<![A-Za-z0-9_=/.@-])@([A-Za-z0-9_]+(?:[.-]+[A-Za-z0-9_]+)*@(?>\(label)(?:\\.\(label))+))(?![A-Za-z0-9_@-]|\\.[\\p{L}\\p{N}])"
        do {
            return try NSRegularExpression(pattern: source)
        } catch {
            // パターンは固定の文字列で、組み立てに失敗するのは書き間違えたときだけなので、起動時に止める。
            preconditionFailure("正規表現が不正です: \(source)")
        }
    }()

    /// 続けて読むと1つのハンドルになる範囲が書式で分かれていると、片方だけでは別の人のハンドルになるので、文字をつないで探す。
    /// リンクにするのは、1つの文字のインラインに収まるハンドルだけ。書式をまたぐものとコードの中の文字はそのまま残す。
    static func linked(_ inlines: [RichText.Inline]) -> [RichText.Inline] {
        var joined = ""
        var ranges: [NSRange] = []
        for inline in inlines {
            let text = switch inline {
            case .text(let text, _), .link(let text, _, _, _): text
            default: "\n"
            }
            ranges.append(NSRange(location: joined.utf16.count, length: text.utf16.count))
            joined += text
        }
        let source = joined as NSString
        let matches = pattern.matches(in: joined, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return inlines }
        return zip(inlines, ranges).flatMap { inline, range in
            split(inline, spanning: range, in: source, matches: matches)
        }
    }

    private static func split(_ inline: RichText.Inline, spanning range: NSRange, in source: NSString, matches: [NSTextCheckingResult]) -> [RichText.Inline] {
        guard case .text(_, let style) = inline, !style.contains(.code) else { return [inline] }
        var result: [RichText.Inline] = []
        var location = range.location
        for match in matches where match.range.location >= range.location && NSMaxRange(match.range) <= NSMaxRange(range) {
            if match.range.location > location {
                result.append(.text(source.substring(with: NSRange(location: location, length: match.range.location - location)), style))
            }
            result.append(.link(source.substring(with: match.range), .handle(acct: source.substring(with: match.range(at: 1))), style))
            location = NSMaxRange(match.range)
        }
        guard location > range.location else { return [inline] }
        if location < NSMaxRange(range) {
            result.append(.text(source.substring(with: NSRange(location: location, length: NSMaxRange(range) - location)), style))
        }
        return result
    }
}
