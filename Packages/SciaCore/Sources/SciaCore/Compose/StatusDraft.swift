public import Foundation

/// 投稿する内容。
public struct StatusDraft: Sendable, Equatable {
    public var text: String
    /// 空なら注意書きなしで投稿する。
    public var spoilerText: String
    public var visibility: Status.Visibility
    public let inReplyToID: String?
    /// 送り直しても二重に投稿されないよう、下書きごとに決めてサーバーに渡す。
    public let idempotencyKey: String

    public init(
        text: String = "",
        spoilerText: String = "",
        visibility: Status.Visibility = .public,
        inReplyToID: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.text = text
        self.spoilerText = spoilerText
        self.visibility = visibility
        self.inReplyToID = inReplyToID
        self.idempotencyKey = idempotencyKey
    }

    /// 返信の下書き。返信先の投稿者と、その投稿でメンションされた相手を宛先に入れる。自分は入れない。
    /// 公開範囲は、Mastodonのweb UIと同じく、返信先と`defaultVisibility`のうち届く範囲が狭い方にする。
    /// 返信先がサーバー独自の公開範囲なら、投稿できるとは限らないため、フォロワー限定にする。
    public static func reply(to status: Status, myAccountID: String, defaultVisibility: Status.Visibility = .public) -> StatusDraft {
        let target = status.displayed
        var seen: Set<String> = []
        let recipients = ([(target.account.id, target.account.acct)] + target.mentions.map { ($0.id, $0.acct) })
            .filter { id, acct in id != myAccountID && seen.insert(acct).inserted }
            .map { "@\($0.1)" }
        let visibility: Status.Visibility = switch target.visibility {
        case .other: .private
        default: target.visibility.narrower(defaultVisibility)
        }
        return StatusDraft(
            text: recipients.isEmpty ? "" : recipients.joined(separator: " ") + " ",
            spoilerText: target.spoilerText,
            visibility: visibility,
            inReplyToID: target.id
        )
    }

    /// サーバーと同じ数え方での文字数。
    public func length(charactersReservedPerURL: Int) -> Int {
        StatusLength.count(text: text, spoilerText: spoilerText, charactersReservedPerURL: charactersReservedPerURL)
    }

    /// 送れる内容になっている。本文が空白だけなら送れない。
    public func canPost(maxCharacters: Int, charactersReservedPerURL: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && length(charactersReservedPerURL: charactersReservedPerURL) <= maxCharacters
    }
}

/// Mastodonの`StatusLengthValidator`と同じく、注意書きと本文を合わせた書記素クラスタの数を数える。
/// 本文中のURLは決まった文字数、`@user@domain`のメンションは`@user`の分だけ数える。
///
/// サーバーはtwitter-textでURLとメンションを抜き出すが、ここでは正規表現で近似する。URLの末尾の句読点や括弧の扱いなど、
/// twitter-textの細かい規則とずれる場合は、上限の付近で数え方が数文字違うことがある。超えた分はサーバーが422で拒むため、
/// 規則を移植する手間に見合わないと判断している。
/// https://github.com/mastodon/mastodon/blob/main/app/validators/status_length_validator.rb
public enum StatusLength {
    public static func count(text: String, spoilerText: String, charactersReservedPerURL: Int) -> Int {
        spoilerText.count + countable(text, charactersReservedPerURL: charactersReservedPerURL).count
    }

    // パターンは固定の文字列で、組み立てに失敗するのは書き間違えたときだけなので、起動時に止める。
    private static let urlPattern = regex(#"https?://[^\s<>"]+"#)
    /// MastodonのAccount::MENTION_REと同じ形。
    private static let mentionPattern = regex(#"(?<![=/\w])@([a-z0-9_]+(?:[a-z0-9_.-]+[a-z0-9_]+)?)(?:@[\w.-]+\w+)?"#, options: [.caseInsensitive])

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("正規表現が不正です: \(pattern)")
        }
    }

    private static func countable(_ text: String, charactersReservedPerURL: Int) -> String {
        let placeholder = String(repeating: "x", count: charactersReservedPerURL)
        var result = text
        for match in urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let url = result[range]
            // 文末の句読点はURLに含めない。
            let trailing = url.reversed().prefix { ".,:;!?".contains($0) }.count
            let urlEnd = result.index(range.upperBound, offsetBy: -trailing)
            result.replaceSubrange(range.lowerBound..<urlEnd, with: placeholder)
        }
        let mentions = mentionPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in mentions.reversed() {
            guard let range = Range(match.range, in: result), let username = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: "@" + result[username])
        }
        return result
    }
}
