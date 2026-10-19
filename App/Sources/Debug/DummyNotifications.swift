#if DEBUG
import SciaCore
import UIKit

/// ステータスバーに流す通知を、通信せずに続けざまに届ける。`scia-debug://dummy/notifications`で呼ぶ。
/// 1件ずつのときの長さと、溜まったときに速く流れるところを1回で見られるよう、まとめて届けたあと、間をおいて1件ずつ届ける。
/// 通知タブの一覧と読んだ位置を乱さないよう、通知の一覧には入れない。
@MainActor
enum DummyNotifications {
    static func stream(into ticker: StatusBarTicker) {
        let delays: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 9]
        let schedule = zip(delays, samples).map { (delay: $0, item: $1) }
        for (index, entry) in schedule.enumerated() {
            Task {
                try? await Task.sleep(for: .seconds(entry.delay))
                ticker.receive(StatusBarTickerItem(id: "dummy-\(index)", kind: entry.item.kind, account: entry.item.account, subject: entry.item.subject))
            }
        }
    }

    /// 流す通知の見本。種類、名前と本文の長さ、画像だけの投稿、閲覧注意、注意書きを1つずつ含める。
    /// デバッグメニューの「ステータスバーの通知を出し続ける」でも、この順に1件ずつ出す。
    static var samples: [StatusBarTickerItem] {
        [
            item(.favourite, from: alice, subject: text("<p>今日は駅前のパン屋が開いていたので、久しぶりにクロワッサンを買った</p>")),
            item(.reblog, from: bob, subject: text("<p>今日は駅前のパン屋が開いていたので、久しぶりにクロワッサンを買った</p>")),
            item(.favourite, from: longName, subject: text("<p>とても長い本文。狭い場所に収まらない分は末尾を省いて出すので、どこで切れるかを確かめる</p>")),
            reply,
            item(.favourite, from: alice, subject: media(sensitive: false)),
            item(.follow, from: dave, subject: .handle("@dave@remote.example")),
            item(.reblog, from: carol, subject: media(sensitive: true)),
            item(.quote, from: bob, subject: .text(RichText.plain("閲覧注意: 映画の結末について", emojis: []))),
            item(.favourite, from: dave, subject: text("<p>1件だけ届いたときは、ゆっくり出す</p>")),
        ]
    }

    /// 返信は、宛先のメンションを省くところも見るため、実物と同じく投稿から作る。
    private static var reply: StatusBarTickerItem {
        guard let url = URL(string: "https://remote.example/@me") else { return item(.mention, from: carol, subject: .none) }
        let me = Mention(id: "me", username: "me", url: url, acct: "me")
        let status = Status(
            id: "dummy-reply",
            createdAt: .now,
            account: carol,
            content: #"<p><span class="h-card"><a href="https://remote.example/@me" class="u-url mention">@<span>me</span></a></span> ありがとうございます！助かりました</p>"#,
            spoilerText: "",
            url: nil,
            mentions: [me]
        )
        let notification = MastodonNotification(id: "dummy-reply", type: .mention, createdAt: .now, account: carol, status: status)
        return StatusBarTickerItem(notification) ?? item(.mention, from: carol, subject: .none)
    }

    private static func item(_ kind: MastodonNotification.Kind, from account: Account, subject: StatusBarTickerItem.Subject) -> StatusBarTickerItem {
        StatusBarTickerItem(id: "", kind: kind, account: account, subject: subject)
    }

    private static func text(_ html: String) -> StatusBarTickerItem.Subject {
        .text(RichText.html(html, emojis: []).singleLineExcerpt)
    }

    private static func media(sensitive: Bool) -> StatusBarTickerItem.Subject {
        guard let attachment = DummyMedia.attachments(idPrefix: "ticker").first else { return .none }
        return .media(attachment, isSensitive: sensitive)
    }

    private static let alice = account("alice", "アリス", color: .systemPink)
    private static let bob = account("bob", "Bob", color: .systemGreen)
    private static let carol = account("carol", "キャロル🌙", color: .systemPurple)
    private static let dave = account("dave", "dave", color: .systemOrange)
    private static let longName = account("longname", "とても長い表示名のアカウントで名前が収まらない", color: .systemTeal)

    private static func account(_ username: String, _ displayName: String, color: UIColor) -> Account {
        Account(id: "dummy-\(username)", username: username, acct: "\(username)@remote.example", displayName: displayName, avatar: CatalogFixtures.imageURL(width: 120, height: 120, color: color))
    }
}
#endif
