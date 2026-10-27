public import Foundation

/// 投稿する内容。
public struct StatusDraft: Sendable, Equatable {
    public var text: String
    /// 空なら注意書きなしで投稿する。
    public var spoilerText: String
    /// 注意書きの欄を出している。注意書きが空でも、添付があれば添付を閲覧注意にする。注意書きがあれば、falseでも出しているものとして扱う。
    /// Mastodonのweb UIと同じく、閲覧注意を注意書きの欄で兼ねるため。決まりはdocs/compose.mdの「閲覧注意」にある。
    public var hasSpoiler: Bool
    public var visibility: Status.Visibility
    public let inReplyToID: String?
    /// 引用する投稿のID。Mastodonは引用と添付・投票を一緒に付けられない。
    public let quotedStatusID: String?
    /// 添付するメディア。この順番で投稿に並ぶ。
    public var attachments: [DraftAttachment]
    /// 付ける投票。付けなければnil。Mastodonは投票と添付を一緒に付けられない。
    public var poll: PollDraft?
    /// 送り直しても二重に投稿されないよう、下書きごとに決めてサーバーに渡す。
    public let idempotencyKey: String
    /// 自分の投稿の編集なら、元の投稿から引き継ぐもの。新しい投稿ならnil。
    public let editing: StatusEditTarget?
    /// 予約する日時。すぐ投稿するならnil。編集では予約できない。
    public var scheduledAt: Date?

    public init(
        text: String = "",
        spoilerText: String = "",
        hasSpoiler: Bool = false,
        visibility: Status.Visibility = .public,
        inReplyToID: String? = nil,
        quotedStatusID: String? = nil,
        attachments: [DraftAttachment] = [],
        poll: PollDraft? = nil,
        idempotencyKey: String = UUID().uuidString,
        editing: StatusEditTarget? = nil,
        scheduledAt: Date? = nil
    ) {
        self.text = text
        self.spoilerText = spoilerText
        self.hasSpoiler = hasSpoiler
        self.visibility = visibility
        self.inReplyToID = inReplyToID
        self.quotedStatusID = quotedStatusID
        self.attachments = attachments
        self.poll = poll
        self.idempotencyKey = idempotencyKey
        self.editing = editing
        self.scheduledAt = scheduledAt
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

    /// 引用の下書き。ブーストなら元の投稿を引用する。宛先と注意書きは入れない。
    /// 公開範囲は、返信と同じく、引用元と`defaultVisibility`のうち届く範囲が狭い方にする。
    /// 引用元がフォロワー限定より狭いかサーバー独自の公開範囲なら、`maxVisibility(quoting:)`のフォロワー限定までにする。
    public static func quote(of status: Status, defaultVisibility: Status.Visibility = .public) -> StatusDraft {
        let target = status.displayed
        let ceiling = maxVisibility(quoting: target) ?? target.visibility
        return StatusDraft(visibility: defaultVisibility.narrower(ceiling), quotedStatusID: target.id)
    }

    /// 引用するときに選べる、いちばん広い公開範囲。制限がなければnil。
    /// Mastodonは、フォロワー限定の投稿の引用を、フォロワー限定（かそれより狭い範囲）でしか受け付けない。
    /// サーバー独自の公開範囲の投稿も、どこまで届くか分からないため、同じくフォロワー限定までにする。
    /// https://docs.joinmastodon.org/client/quotes/#new-parameters-to-existing-endpoints
    public static func maxVisibility(quoting status: Status) -> Status.Visibility? {
        switch status.displayed.visibility {
        case .public, .unlisted: nil
        case .private, .direct, .other: .private
        }
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

    /// 予約した投稿を書き直す下書き。予約したときに送った内容を戻す。決まりはdocs/compose.mdの「書き直す」にある。
    /// 添付は、アップロードの済んだ添付として並べる。元の予約に付いたまま新しい投稿に付け直せるので、元の予約は送れたあとに取り消す。
    /// 公開範囲を送っていない予約では、`defaultVisibility`にする。
    public static func rewrite(of scheduled: ScheduledStatus, defaultVisibility: Status.Visibility = .public) -> StatusDraft {
        let params = scheduled.params
        let attachments = scheduled.mediaAttachments.map { attachment in
            DraftAttachment(state: .uploaded(attachment), description: attachment.description ?? "")
        }
        return StatusDraft(
            text: params.text,
            spoilerText: params.spoilerText,
            hasSpoiler: !params.spoilerText.isEmpty || (params.sensitive && !attachments.isEmpty),
            visibility: params.visibility ?? defaultVisibility,
            inReplyToID: params.inReplyToID,
            quotedStatusID: params.quotedStatusID,
            attachments: attachments,
            poll: params.poll,
            scheduledAt: scheduled.scheduledAt
        )
    }

    /// 送れる内容になっている。
    /// 本文が空白だけでも、メディアを添付しているか引用していれば送れる（Mastodonは`media_ids`か引用があれば`status`を省ける）。投票では省けない。
    /// 添付ファイルは、上限の数以内で、全部のアップロードと代替テキストの送信が済むまで送れない。
    /// 投票は、サーバーが受け付ける内容で、添付と一緒でないときだけ送れる。
    /// 引用は、添付も投票もないときだけ送れる。
    public func canPost(maxCharacters: Int, charactersReservedPerURL: Int, maxMediaAttachments: Int, pollLimits: PollLimits = .mastodonDefault) -> Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || quotedStatusID != nil)
            && (quotedStatusID == nil || (attachments.isEmpty && poll == nil))
            && length(charactersReservedPerURL: charactersReservedPerURL) <= maxCharacters
            && attachments.count <= maxMediaAttachments
            && mediaIDs != nil
            && poll.map { $0.isValid(limits: pollLimits) && attachments.isEmpty } ?? true
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

    /// MastodonのAccount::MENTION_REと同じ形。
    private static let mentionPattern = regex(#"(?<![=/\w])@([a-z0-9_]+(?:[a-z0-9_.-]+[a-z0-9_]+)?)(?:@[\w.-]+\w+)?"#, options: [.caseInsensitive])

    private static func countable(_ text: String, charactersReservedPerURL: Int) -> String {
        let placeholder = String(repeating: "x", count: charactersReservedPerURL)
        var result = text
        for range in StatusURLs.ranges(in: text).reversed() {
            result.replaceSubrange(range, with: placeholder)
        }
        let mentions = mentionPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in mentions.reversed() {
            guard let range = Range(match.range, in: result), let username = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: "@" + result[username])
        }
        return result
    }
}

/// 本文の中のURL。サーバーはtwitter-textでURLを抜き出すが、`StatusLength`と同じ理由で正規表現で近似する。
public enum StatusURLs {
    private static let pattern = regex(#"https?://[^\s<>"]+"#)

    /// 本文に出てくる順の、URLの範囲。文末の句読点はURLに含めない。
    public static func ranges(in text: String) -> [Range<String.Index>] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let trailing = text[range].reversed().prefix { ".,:;!?".contains($0) }.count
            return range.lowerBound..<text.index(range.upperBound, offsetBy: -trailing)
        }
    }
}

// パターンは固定の文字列で、組み立てに失敗するのは書き間違えたときだけなので、起動時に止める。
private func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        preconditionFailure("正規表現が不正です: \(pattern)")
    }
}
