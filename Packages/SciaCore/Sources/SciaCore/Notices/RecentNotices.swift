public import Foundation
public import Observation

/// 「最近の失敗」の一覧に並べる、処理の途中と最近の失敗。出方の決まりはdocs/notices.mdの「最近の失敗」にある。セッションごとに1つ持つ。
///
/// 起動している間だけメモリに持ち、ログには書かない。どの投稿の失敗かを持つため、IDを伏せた「接続の状態」の記録とは分ける。
@MainActor
@Observable
public final class RecentNotices {
    /// 知らせが結び付いた投稿。行から投稿を開くために持つ。
    public struct Subject: Sendable, Equatable {
        /// 操作した要素のID。ブーストならブーストのID。
        public let statusID: Status.ID
        /// 中身の投稿のID。ブーストなら元の投稿のID。
        public let displayedID: Status.ID
        /// 一覧になかったときに開く、投稿のページ。
        public let url: URL?
        public let authorName: String
        /// 本文を1行にしたもの。注意書きつきの投稿は、一覧と同じく注意書きだけにする。
        /// 一覧の行では画像を描かないため、名前と本文のカスタム絵文字は省く。
        public let excerpt: String

        public init(statusID: Status.ID, displayedID: Status.ID, url: URL?, authorName: String, excerpt: String) {
            self.statusID = statusID
            self.displayedID = displayedID
            self.url = url
            self.authorName = authorName
            self.excerpt = excerpt
        }

        public init(_ status: Status) {
            let displayed = status.displayed
            let text = displayed.spoilerText.isEmpty
                ? MastodonHTMLParser(mentions: displayed.mentions, emojis: displayed.emojis).parse(displayed.content)
                : RichText.plain(displayed.spoilerText, emojis: displayed.emojis)
            let name = Self.textWithoutEmojis(RichText.plain(displayed.account.displayName, emojis: displayed.account.emojis))
            self.init(
                statusID: status.id,
                displayedID: displayed.id,
                url: displayed.url,
                authorName: name.isEmpty ? displayed.account.acct : name,
                excerpt: Self.textWithoutEmojis(text)
            )
        }

        /// カスタム絵文字を省き、段落と改行を空白でつないだ1行の文字。
        private static func textWithoutEmojis(_ text: RichText) -> String {
            let words = text.blocks.map { block in
                (block.listMarker ?? "") + block.inlines.map { inline in
                    switch inline {
                    case .text(let text, _), .link(let text, _, _): text
                    case .emoji: ""
                    case .lineBreak: " "
                    }
                }.joined()
            }
            return words.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
    }

    public struct Failure: Sendable, Identifiable, Equatable {
        public let id: UUID
        /// 何が失敗したか。「お気に入りを変更できませんでした」など。
        public let title: String
        public let reason: ErrorPresentation
        public let subject: Subject?
        public let date: Date
    }

    /// 処理の途中。済んだら`end`で外す。
    public struct Activity: Sendable, Identifiable, Equatable {
        public let id: String
        public var title: String
        /// 進み具合など、文言のあとに添える値。
        public var value: String?
        public var subject: Subject?

        public init(id: String, title: String, value: String? = nil, subject: Subject? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.subject = subject
        }
    }

    /// 残す失敗の数。超えたら古いものから捨てる。
    public static let failureLimit = 30

    /// 始めた順。
    public private(set) var activities: [Activity] = []
    /// 新しい順。
    public private(set) var failures: [Failure] = []
    @ObservationIgnored private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 失敗を残す。成功は残さない。
    @discardableResult
    public func recordFailure(title: String, reason: ErrorPresentation, subject: Subject? = nil) -> Failure {
        let failure = Failure(id: UUID(), title: title, reason: reason, subject: subject, date: now())
        failures.insert(failure, at: 0)
        if failures.count > Self.failureLimit {
            failures.removeLast(failures.count - Self.failureLimit)
        }
        return failure
    }

    /// 処理の途中を足すか、同じidのものを書き換える。書き換えても並びの位置は変えない。
    public func update(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index] = activity
        } else {
            activities.append(activity)
        }
    }

    public func end(_ activityID: Activity.ID) {
        activities.removeAll { $0.id == activityID }
    }
}

/// 出たままの知らせが重なったときに、チップに出す1件を選ぶ。決まりはdocs/notices.mdの「チップ」にある。
public enum PersistentNoticeChoice {
    /// 失敗を優先し、次に処理の途中、その中では新しいものを選ぶ。
    /// - Parameter items: 出た順（古いものが先）。
    /// - Returns: 選んだ1件と、ほかの件数。空ならnil。
    public static func choose<Item>(_ items: [Item], isFailure: (Item) -> Bool) -> (item: Item, others: Int)? {
        guard let chosen = items.last(where: isFailure) ?? items.last else { return nil }
        return (chosen, items.count - 1)
    }
}
