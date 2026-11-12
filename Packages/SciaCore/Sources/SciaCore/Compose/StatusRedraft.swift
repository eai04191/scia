import Foundation

/// 削除して書き直している自分の投稿。元の投稿は、書き直した投稿を送るときに削除する。
/// 決まりはdocs/compose.mdの「自分の投稿を削除して書き直す」にある。
public struct StatusRedraft: Sendable, Equatable {
    /// 書き直している元の投稿。ブーストではなく、元の投稿そのもの。
    public let status: Status
    public internal(set) var deletion: Deletion

    public init(status: Status, deletion: Deletion = .pending) {
        self.status = status
        self.deletion = deletion
    }

    /// 元の投稿を削除したか。
    public enum Deletion: Sendable, Equatable {
        /// まだ削除していない。書き直しをやめても、元の投稿は残る。
        case pending
        /// 削除を送ったが、応答を受け取れず、届いたか分からない。送り直すときは削除から送り直す。
        case uncertain
        /// 削除した（ほかの端末で消してあったときを含む）。中身はもう下書きにしか残っていない。
        case done
    }

    /// 元の投稿がもうないかもしれない。書き直しをやめると中身を失うので、やめる前に確かめる。
    public var mayHaveDeleted: Bool {
        deletion != .pending
    }
}

/// 削除して書き直す投稿を送るときに使うもの。
public struct ComposeRedraftService {
    /// 元の投稿を、添付を残して削除する。
    public var deleteStatus: (Status.ID) async throws -> Void
    /// 削除した投稿の添付が、新しい投稿に付けられるようになるまで待つ。サーバーのIDを受け取る。
    public var waitUntilReleased: (String) async throws -> MediaAttachment

    public init(
        deleteStatus: @escaping (Status.ID) async throws -> Void,
        waitUntilReleased: @escaping (String) async throws -> MediaAttachment
    ) {
        self.deleteStatus = deleteStatus
        self.waitUntilReleased = waitUntilReleased
    }

    /// 削除して書き直さない画面とテストで使う。
    public static var unavailable: ComposeRedraftService {
        ComposeRedraftService(deleteStatus: { _ in throw CancellationError() }, waitUntilReleased: { _ in throw CancellationError() })
    }
}

extension StatusDraft {
    /// 自分の投稿を削除して書き直す下書き。本文と注意書きは、HTMLの`content`ではなく、書いたときのソースから入れる。
    /// 添付は、元の投稿に付いたままの、アップロードの済んだ添付として並べる。元の投稿を削除してから、新しい投稿に付け直す。
    /// 投票は新しい投稿の投票になるので、締め切りは元の投票の長さにいちばん近い選択肢にする。
    /// サーバー独自の公開範囲は、どこまで届くか分からないため、返信と同じくフォロワー限定にする。
    public static func redraft(of status: Status, source: StatusSource, pollLimits: PollLimits = .mastodonDefault) -> StatusDraft {
        let attachments = status.mediaAttachments.map { attachment in
            DraftAttachment(state: .uploaded(attachment), description: attachment.description ?? "", isHeldByRedraftedStatus: true)
        }
        let visibility: Status.Visibility = switch status.visibility {
        case .other: .private
        default: status.visibility
        }
        return StatusDraft(
            text: source.text,
            spoilerText: source.spoilerText,
            hasSpoiler: !source.spoilerText.isEmpty || (status.sensitive && !attachments.isEmpty),
            visibility: visibility,
            inReplyToID: status.inReplyToId,
            quotedStatusID: status.quote?.quotedStatusID,
            attachments: attachments,
            poll: status.poll.map { PollDraft(redrafting: $0, postedAt: status.createdAt, limits: pollLimits) },
            language: status.language,
            quotePolicy: status.quoteApproval?.policy
        )
    }
}

extension PollDraft {
    /// 削除して書き直す投稿の投票。選択肢、複数選べるか、締め切るまで票数を隠すかを戻す。
    /// 票数を隠すかはPoll entityが返さないので、締め切る前の投票で票数がnullかで見分ける（`Poll#show_totals_now?`）。
    /// 締め切った投票は見分けられないので、隠さないにする。
    /// 締め切りは、元の投票の長さ（投稿してから締め切りまで）にいちばん近い選択肢にする。締め切りが分からなければ1日にする。
    init(redrafting poll: Poll, postedAt: Date, limits: PollLimits) {
        let choices = Self.expiryChoices(within: limits)
        let fallback = choices.contains(86_400) ? 86_400 : choices.first ?? limits.expirationRange.lowerBound
        let expiresIn = poll.expiresAt.map { expiresAt in
            let duration = expiresAt.timeIntervalSince(postedAt)
            return choices.min { abs(Double($0) - duration) < abs(Double($1) - duration) } ?? fallback
        } ?? fallback
        self.init(
            options: Self.editingOptions(poll.options.map(\.title), maxOptions: limits.maxOptions),
            multiple: poll.multiple,
            hidesTotals: !poll.expired && poll.options.contains { $0.votesCount == nil },
            expiresIn: expiresIn
        )
    }
}
