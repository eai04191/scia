#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の投稿の投票。一覧と同じく`TimelineViewController`の組み立てを通し、選んでいる状態や送っている途中は`PollChoices`で直接渡す。
/// 投票したときの棒の動きと、投票前と結果で行の高さが変わらないことは、`scia-debug://dummy/polls`の実物で確かめる。
enum PollCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
    private static let other = Fixtures.account(displayName: "ほかの人", acct: "other@example.com")

    /// 締め切った投票。1位が2つ並ぶ。通知の行のカタログでも使う。
    static let endedPoll = poll(expiresIn: -3_600, options: [("1位で並んだ選択肢", 12), ("もう1つの1位", 12), ("負けた選択肢", 3)], voted: true, ownVotes: [1])

    @MainActor
    static func states() -> [CatalogState] {
        let open = poll(options: [("はい", 12), ("いいえ", 5), ("どちらでもない", 3)])
        let multiple = poll(multiple: true, expiresIn: 3_600 * 5, options: [("朝", 4), ("昼", 7), ("夜", 7), ("深夜", 0)], votersCount: 10)
        let longTitles = poll(options: [
            (String(repeating: "選択肢の文字が長く、何行にもわたるときの折り返しを確かめる。", count: 2), 30),
            ("短い選択肢", 1),
        ])
        let emojiURL = Fixtures.imageURL(width: 64, height: 64, color: .systemOrange)
        let emojiTitles = poll(options: [(":square: 四角", 3), (":square::square: 2つ", 1)], emojis: emojiURL.map { [CustomEmoji(shortcode: "square", url: $0, staticUrl: $0)] } ?? [])
        /// - Parameter choices: 一覧で覚えている、選んでいる選択肢などの状態を、組み立てる前に当てる。
        func post(_ title: String, _ poll: Poll, account: Account = other, content: String = "<p>投票の付いた投稿。</p>", spoilerText: String = "", card: PreviewCard? = nil, choices: @escaping (inout PollChoices, Poll.ID) -> Void = { _, _ in }) -> CatalogState {
            CatalogState(title: title) {
                let timeline = TimelineViewController(texts: .home, refresh: {})
                timeline.myAccountID = author.id
                choices(&timeline.pollChoices, poll.id)
                let status = Status(
                    id: UUID().uuidString,
                    createdAt: .now.addingTimeInterval(-3_600),
                    account: account,
                    content: content,
                    spoilerText: spoilerText,
                    url: nil,
                    poll: poll,
                    card: card
                )
                return CatalogFrame.bordered(PostContentView(configuration: timeline.contentConfiguration(for: status, base: .cell())))
            }
        }
        return [
            post("投票前（複数選べない）", open),
            post("投票前（1つ選んだ）", open) { choices, _ in choices.toggle(0, in: open) },
            post("投票前（複数選べる、2つ選んだ）", multiple) { choices, _ in
                choices.toggle(1, in: multiple)
                choices.toggle(2, in: multiple)
            },
            post("投票を送っている途中", open) { choices, id in
                choices.toggle(1, in: open)
                choices.beginSubmitting(id)
            },
            post("結果を見ると選んだ（投票に戻れる）", open) { $0.reveal($1) },
            post("投票済み（自分の票にチェックマーク）", poll(options: [("はい", 13), ("いいえ", 5), ("どちらでもない", 3)], voted: true, ownVotes: [0])),
            post("投票済みで、結果を読み直している途中", poll(options: [("はい", 13), ("いいえ", 5)], voted: true, ownVotes: [1])) { $0.beginRefreshing($1) },
            post("複数選べる投票に投票済み（割合は投票した人の数に対する）", poll(multiple: true, expiresIn: 3_600 * 5, options: [("朝", 5), ("昼", 8), ("夜", 7), ("深夜", 0)], votersCount: 11, voted: true, ownVotes: [0, 1])),
            post("締め切るまで票数を隠す投票に投票済み", poll(expiresIn: 60 * 30, options: [("A", nil), ("B", nil)], votesCount: 8, voted: true, ownVotes: [1])),
            post("締め切るまで票数を隠す投票（投票前、結果を見られない）", poll(expiresIn: 60 * 30, options: [("A", nil), ("B", nil)], votesCount: 7)),
            post("締め切った（1位が2つ並ぶ）", endedPoll),
            post("まだ票のない投票の結果", poll(options: [("A", 0), ("B", 0)])) { $0.reveal($1) },
            post("自分の投票（締め切り前、投票できない）", poll(options: [("はい", 2), ("いいえ", 1)], voted: true), account: author),
            post("締め切りまで1分を切った", poll(expiresIn: 42, options: [("はい", 2), ("いいえ", 1)])),
            post("人数の多い投票", poll(multiple: true, options: [("はい", 123_456), ("いいえ", 23_456)], votersCount: 140_000, voted: true, ownVotes: [0])),
            post("選択肢の文字が長い（投票前）", longTitles),
            post("選択肢の文字が長い（結果）", longTitles) { $0.reveal($1) },
            post("選択肢にカスタム絵文字", emojiTitles),
            post("本文のない投票", open, content: ""),
            post("投票とリンクカード", open, content: #"<p>投票とリンク <a href="https://news.example/articles/1">news.example/articles/1</a></p>"#),
            post("注意書き（閉じた、投票は隠れる）", open, spoilerText: "ネタバレ"),
        ]
    }

    private static func poll(
        multiple: Bool = false,
        expiresIn: TimeInterval = 86_400,
        options: [(String, Int?)],
        votesCount: Int? = nil,
        votersCount: Int? = nil,
        emojis: [CustomEmoji] = [],
        voted: Bool = false,
        ownVotes: [Int] = []
    ) -> Poll {
        Poll(
            id: UUID().uuidString,
            expiresAt: .now.addingTimeInterval(expiresIn),
            expired: expiresIn < 0,
            multiple: multiple,
            votesCount: votesCount ?? options.compactMap(\.1).reduce(0, +),
            votersCount: multiple ? votersCount : nil,
            options: options.map { Poll.Option(title: $0.0, votesCount: $0.1) },
            emojis: emojis,
            voted: voted,
            ownVotes: ownVotes
        )
    }
}
#endif
