public import Foundation

/// 投稿する内容。
public struct StatusDraft: Sendable, Equatable {
    public var text: String
    /// 空なら注意書きなしで投稿する。
    public var spoilerText: String
    /// 注意書きの欄を出している。注意書きが空でも、添付があれば添付を閲覧注意にする。注意書きがあれば、falseでも出しているものとして扱う。
    /// Mastodonのweb UIと同じく、閲覧注意を注意書きの欄で兼ねるため。決まりはdocs/vision.mdの「投稿欄」にある。
    public var hasSpoiler: Bool
    public var visibility: Status.Visibility
    public let inReplyToID: String?
    /// 添付するメディア。この順番で投稿に並ぶ。
    public var attachments: [DraftAttachment]
    /// 送り直しても二重に投稿されないよう、下書きごとに決めてサーバーに渡す。
    public let idempotencyKey: String

    public init(
        text: String = "",
        spoilerText: String = "",
        hasSpoiler: Bool = false,
        visibility: Status.Visibility = .public,
        inReplyToID: String? = nil,
        attachments: [DraftAttachment] = [],
        idempotencyKey: String = UUID().uuidString
    ) {
        self.text = text
        self.spoilerText = spoilerText
        self.hasSpoiler = hasSpoiler
        self.visibility = visibility
        self.inReplyToID = inReplyToID
        self.attachments = attachments
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

    /// 添付を閲覧注意にする。注意書きの欄を出していて、添付があるとき。
    /// 添付のない投稿に付けても、Mastodonは何も隠さないので付けない（注意書きがあれば、サーバーが投稿を閲覧注意にする）。
    public var sensitive: Bool {
        (hasSpoiler || !spoilerText.isEmpty) && !attachments.isEmpty
    }

    /// サーバーと同じ数え方での文字数。
    public func length(charactersReservedPerURL: Int) -> Int {
        StatusLength.count(text: text, spoilerText: spoilerText, charactersReservedPerURL: charactersReservedPerURL)
    }

    /// 投稿の`media_ids[]`に並べるサーバー側のID。添付ファイルが1つでも済んでいなければnil。
    public var mediaIDs: [String]? {
        var ids: [String] = []
        for attachment in attachments {
            guard attachment.isReady, let serverID = attachment.serverID else { return nil }
            ids.append(serverID)
        }
        return ids
    }

    /// 送れる内容になっている。
    /// 本文が空白だけでも、メディアを添付していれば送れる（Mastodonは`media_ids`があれば`status`を省ける）。
    /// 添付ファイルは、上限の数以内で、全部のアップロードと代替テキストの送信が済むまで送れない。
    public func canPost(maxCharacters: Int, charactersReservedPerURL: Int, maxMediaAttachments: Int) -> Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && length(charactersReservedPerURL: charactersReservedPerURL) <= maxCharacters
            && attachments.count <= maxMediaAttachments
            && mediaIDs != nil
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
