public import Foundation

/// 編集のために読む、投稿を書いたときの本文と注意書き。`content`はHTMLなので、編集の元にはこちらを使う。
/// https://docs.joinmastodon.org/entities/StatusSource/
public struct StatusSource: Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let spoilerText: String

    public init(id: String, text: String, spoilerText: String) {
        self.id = id
        self.text = text
        self.spoilerText = spoilerText
    }
}

/// 下書きが自分の投稿の編集であるときの、元の投稿から引き継いで送り直すもの。
///
/// Mastodonの編集は、送らなかった添付・投票・注意書きを消す（`StatusesController#update`が、送らなかった項目もnilとして渡すため）。
/// そのため、投稿欄で変えられない投票も、元の値のまま毎回送り直す。
/// https://github.com/mastodon/mastodon/blob/main/app/services/update_status_service.rb
public struct StatusEditTarget: Sendable, Equatable {
    public let statusID: Status.ID
    /// 元の投稿の投票。投票がなければnil。
    public let poll: PollResubmission?

    public init(statusID: Status.ID, poll: PollResubmission?) {
        self.statusID = statusID
        self.poll = poll
    }
}

/// 編集で送り直す投票。選択肢と複数選べるかを変えなければ、票は残る。
public struct PollResubmission: Sendable, Equatable {
    public let options: [String]
    public let expiresAt: Date
    public let multiple: Bool
    /// 締め切るまで票数を隠す。Poll entityはこの設定を返さないが、締め切る前の投票で選択肢の票数がnullなら隠している（`Poll#show_totals_now?`）。
    public let hideTotals: Bool

    /// 締め切りが分からない投票と、締め切った投票では作らない。
    public init?(_ poll: Poll, now: Date) {
        guard let expiresAt = poll.expiresAt, !poll.expired, expiresAt > now else { return nil }
        options = poll.options.map(\.title)
        self.expiresAt = expiresAt
        multiple = poll.multiple
        hideTotals = poll.options.contains { $0.votesCount == nil }
    }

    /// 送る`poll[expires_in]`。サーバーは送った時点から数え直すため、締め切りは送るまでにかかった分だけずれる。
    public func expiresIn(now: Date) -> Int {
        Int(expiresAt.timeIntervalSince(now).rounded(.up))
    }
}

extension Status {
    /// サーバーが受け付ける投票の締め切りの短さの下限（`PollExpirationValidator::MIN_EXPIRATION`）。
    /// 投票付きの投稿の編集では、残りの時間をそのまま送り直すため、残りがこれより短いと拒まれる。
    public static let minimumPollDuration: TimeInterval = 5 * 60

    /// `accountID`のアカウントの投稿。ブーストなら元の投稿で見る。
    public func isAuthored(by accountID: String) -> Bool {
        displayed.account.id == accountID
    }

    /// 編集を送れる。投票の締め切りまで5分を切った投稿と、締め切った投稿は、送り直すとサーバーが拒むため送れない。
    /// 自分の投稿かどうかは見ない。
    public func canBeEdited(now: Date) -> Bool {
        guard let poll = displayed.poll else { return true }
        guard let expiresAt = poll.expiresAt, !poll.expired else { return false }
        return expiresAt.timeIntervalSince(now) >= Self.minimumPollDuration
    }
}

extension StatusDraft {
    /// 自分の投稿を編集する下書き。公開範囲と返信先は変えられないため、元の投稿のまま持つ。
    /// 投稿に付いている添付は、アップロードの済んだ添付として並べ、代替テキストは編集と一緒に送る。
    /// 元の投稿で添付を閲覧注意にしていれば、注意書きが空でも注意書きの欄を出す。
    /// 投票を送り直せない（締め切りまで5分を切った、締め切った）投稿ではnilを返す。投票なしで送ると、サーバーが投票を消すため。
    /// メニューを出したときは送り直せても、編集を始めるまでの間に締め切りが近づくことがある。
    public static func edit(of status: Status, source: StatusSource, now: Date) -> StatusDraft? {
        guard status.canBeEdited(now: now) else { return nil }
        let attachments = status.mediaAttachments.map { attachment in
            DraftAttachment(state: .uploaded(attachment), description: attachment.description ?? "", isAttachedToStatus: true)
        }
        return StatusDraft(
            text: source.text,
            spoilerText: source.spoilerText,
            hasSpoiler: !source.spoilerText.isEmpty || (status.sensitive && !attachments.isEmpty),
            visibility: status.visibility,
            inReplyToID: status.inReplyToId,
            attachments: attachments,
            editing: StatusEditTarget(statusID: status.id, poll: status.poll.flatMap { PollResubmission($0, now: now) })
        )
    }

    /// 投稿に付いている添付のうち、代替テキストを書き換えたものと、前に送って届いたか分からないもの。編集の`media_attributes[]`で送る。
    public var changedAttachedDescriptions: [(id: String, description: String)] {
        attachments.compactMap { attachment in
            guard attachment.isAttachedToStatus, case .uploaded(let media) = attachment.state,
                  attachment.hasUnconfirmedDescription || (media.description ?? "") != attachment.description
            else { return nil }
            return (media.id, attachment.description)
        }
    }

    /// 編集で送るフォーム。添付、注意書き、閲覧注意、投票は、変えていなくても毎回送る。送らなければサーバーが消すため。
    /// 添付がなければ`media_ids[]`を送らない。空の値を送ると、サーバーはIDの0として探して拒む。送らなければ添付は外れる。
    func editForm(poll: PollResubmission?, now: Date) -> [URLQueryItem]? {
        guard let mediaIDs else { return nil }
        var form = [
            URLQueryItem(name: "status", value: text),
            URLQueryItem(name: "spoiler_text", value: spoilerText),
            URLQueryItem(name: "sensitive", value: sensitive ? "true" : "false"),
        ]
        form += mediaIDs.map { URLQueryItem(name: "media_ids[]", value: $0) }
        // Rackは配列の中のハッシュを、同じキーがもう一度出たところで次の要素に分ける。要素ごとにidを先に置く。
        for (id, description) in changedAttachedDescriptions {
            form.append(URLQueryItem(name: "media_attributes[][id]", value: id))
            form.append(URLQueryItem(name: "media_attributes[][description]", value: description))
        }
        if let poll {
            form += poll.options.map { URLQueryItem(name: "poll[options][]", value: $0) }
            form.append(URLQueryItem(name: "poll[expires_in]", value: String(poll.expiresIn(now: now))))
            form.append(URLQueryItem(name: "poll[multiple]", value: poll.multiple ? "true" : "false"))
            form.append(URLQueryItem(name: "poll[hide_totals]", value: poll.hideTotals ? "true" : "false"))
        }
        return form
    }
}
