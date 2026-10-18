#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の投稿と通知の行。一覧と同じく`TimelineViewController`の組み立てを通すので、名前の並べ方やアイコンの形、時刻の表記はアプリの設定に従う。
enum PostRowCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
    private static let longFilterTitle = String(repeating: "長いフィルターの名前", count: 4)
    private static let booster = Fixtures.account(
        displayName: "ブーストした人",
        acct: "booster@example.com",
        avatar: Fixtures.imageURL(width: 200, height: 200, color: .systemPink)
    )

    @MainActor
    static func postStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home)
        home.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        // カタログのアカウントを自分として組む一覧。自分の投稿は、フィルターに一致しても畳まずに印を出す。
        let mine = TimelineViewController(texts: .home)
        mine.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: author.id))
        /// - Parameters:
        ///   - expandsSpoiler: 注意書きを開く。フィルターの警告で畳んでいれば、警告を開く。
        ///   - isMine: カタログのアカウントを自分として組む。
        func post(_ title: String, _ status: Status, isPinned: Bool = false, expandsSpoiler: Bool = false, isMine: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let timeline = isMine ? mine : home
                if expandsSpoiler { timeline.toggleSpoiler(of: status) }
                return CatalogFrame.bordered(PostContentView(configuration: timeline.contentConfiguration(for: status, isPinned: isPinned, base: .cell())))
            }
        }
        let longSpoiler = String(repeating: "注意書きが長く、何行にもわたるときの折り返しを確かめる。", count: 4)
        return [
            post("短い本文", status(content: "<p>短い本文。</p>")),
            post("本文が短く、アイコンの方が下まで届く", status(content: "<p>あ</p>")),
            post("長い本文", status(content: "<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しと、行の高さを確かめるための文。", count: 5) + "</p>")),
            post("ブーストされた投稿", status(content: "<p>ブーストされた投稿。</p>", rebloggedBy: booster)),
            post("固定された投稿", status(content: "<p>プロフィールの上に固定された投稿。</p>"), isPinned: true),
            post("注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            post("注意書き（開いた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ"), expandsSpoiler: true),
            post("注意書きが長い（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: longSpoiler)),
            post("注意書きと閲覧注意の画像（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            post("注意書きと閲覧注意の画像（開いた、画像は覆ったまま）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true), expandsSpoiler: true),
            post("注意書きと画像だけで本文がない（開いた）", status(content: "", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemTeal),
            ], sensitive: true), expandsSpoiler: true),
            post("ブーストされた注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", rebloggedBy: booster)),
            post("フィルターの警告", status(content: "<p>警告で畳んだ本文。</p>", filtered: [filter("ネタバレ", .warn)])),
            post("フィルターの警告（名前が長い、2つに一致した）", status(content: "<p>警告で畳んだ本文。</p>", filtered: [filter(longFilterTitle, .warn), filter("ネタバレ", .warn)])),
            post("フィルターの警告と画像とリンクカード（どれも出さない）", status(
                content: #"<p>警告で畳んだ本文。<a href="https://news.example/articles/1">news.example/articles/1</a></p>"#,
                media: [Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange)],
                filtered: [filter("ネタバレ", .warn)]
            )),
            post("フィルターの警告と注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", filtered: [filter("ネタバレ", .warn)])),
            post("フィルターの警告と注意書き（警告を開いた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", filtered: [filter("ネタバレ", .warn)]), expandsSpoiler: true),
            post("ブーストされたフィルターの警告", status(content: "<p>警告で畳んだ本文。</p>", filtered: [filter("ネタバレ", .warn)], rebloggedBy: booster)),
            post("フィルターで画像をぼかす", status(content: "<p>フィルターで画像をぼかした投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], filtered: [filter("ネタバレ", .blur)])),
            post("フィルターで画像をぼかす（閲覧注意も付いた、名前が長い）", status(content: "<p>フィルターで画像をぼかした投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true, filtered: [filter(longFilterTitle, .blur)])),
            post("自分の投稿がフィルターに一致した（畳まずに印を出す）", status(content: "<p>フィルターした話題に自分で触れた投稿。</p>", filtered: [filter("ネタバレ", .hide)]), isMine: true),
            post("自分の投稿が複数のフィルターに一致した（名前が長い、画像つき）", status(content: "<p>フィルターした話題に自分で触れた投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], filtered: [filter(longFilterTitle, .warn), filter("画像", .blur)]), isMine: true),
            post("自分の投稿がフィルターに一致した（注意書き、閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", filtered: [filter("ネタバレ", .warn)]), isMine: true),
            post("フィルターの警告とぼかし（警告を開いた）", status(content: "<p>警告を開くと、画像はぼかしたまま出る。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], filtered: [filter("ネタバレ", .warn), filter("画像", .blur)]), expandsSpoiler: true),
            post("画像2枚", status(content: "<p>画像を2枚添付した投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 1_200, height: 900, color: .systemGreen, description: "緑の地に白い格子"),
            ])),
            post("閲覧注意の画像", status(content: "<p>閲覧注意の画像を添付した投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            post("名前が長い（末尾をぼかす）", status(
                content: "<p>名前が1行に収まらない投稿。</p>",
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com")
            )),
            post("編集された投稿", status(content: "<p>投稿したあとに編集した投稿。</p>", editedAt: .now.addingTimeInterval(-60))),
            post("編集された投稿で名前が長い", status(
                content: "<p>名前が1行に収まらず、編集済みの印も付く投稿。</p>",
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com"),
                editedAt: .now.addingTimeInterval(-60)
            )),
            post("アイコンがない", status(content: "<p>アイコンのURLがないアカウントの投稿。</p>", account: Fixtures.account(acct: "noavatar@example.com", avatar: nil))),
        ]
    }

    /// リンクカードの付いた投稿。サーバーのカードが後から届いても行の高さが変わらないことを、カードとリンク先だけのカードを並べて見比べる。
    @MainActor
    static func linkCardStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home)
        func post(_ title: String, _ status: Status, revealsMedia: Bool = false, expandsSpoiler: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                if revealsMedia { home.mediaCovers.reveal(status) }
                if expandsSpoiler { home.toggleSpoiler(of: status) }
                return CatalogFrame.bordered(PostContentView(configuration: home.contentConfiguration(for: status, base: .cell())))
            }
        }
        let link = "https://news.example/articles/2026/10/link-card"
        let content = #"<p>記事を読んだ。<a href="\#(link)" rel="nofollow noopener" target="_blank"><span class="invisible">https://</span><span class="ellipsis">news.example/articles/2026/10/</span><span class="invisible">link-card</span></a></p>"#
        func card(title: String = "記事の見出し", description: String = "記事の要約が入る。", providerName: String = "News Example", image: URL? = Fixtures.imageURL(width: 400, height: 225, color: .systemIndigo)) -> PreviewCard? {
            URL(string: link).map {
                PreviewCard(url: $0, title: title, description: description, type: .link, providerName: providerName, image: image, width: 400, height: 225, blurhash: Fixtures.blurhash)
            }
        }
        let longText = String(repeating: "見出しや要約が1行に収まらないときに末尾を省くことを確かめる文。", count: 3)
        let pendingCard = LinkCardView(store: Fixtures.pendingMediaImages)
        if let loading = card() {
            pendingCard.apply(LinkCardView.Content(card: .card(loading), padding: home.tuning.value(of: TuningCatalog.linkCardPadding), transitionDuration: 0, thumbnailSide: .left))
        }
        // 画像の位置の設定によらず、左右と文字の方向の組み合わせを並べるため、カードだけを置く。
        func cardOnly(_ title: String, _ linkCard: LinkCard?, side: LinkCardThumbnailSide, coversImage: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let view = LinkCardView(store: AppDependencies.mediaImages)
                if let linkCard {
                    view.apply(LinkCardView.Content(card: linkCard, padding: home.tuning.value(of: TuningCatalog.linkCardPadding), transitionDuration: 0, thumbnailSide: side, coversImage: coversImage))
                }
                let frame = UIView()
                view.translatesAutoresizingMaskIntoConstraints = false
                frame.addSubview(view)
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
                    view.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -8),
                    view.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16),
                    view.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
                ])
                return CatalogFrame.bordered(frame)
            }
        }
        let arabic = card(title: "عنوان المقال باللغة العربية", description: "ملخص المقال يظهر هنا.", providerName: "أخبار")
        return [
            post("サーバーのカード", status(content: content, card: card())),
            cardOnly("画像を右に", card().map(LinkCard.card), side: .right),
            cardOnly("画像を右に（リンク先だけ）", URL(string: link).map(LinkCard.link), side: .right),
            cardOnly("画像を右に（画像のないカード）", card(image: nil).map(LinkCard.card), side: .right),
            cardOnly("右から書く言語の見出し（画像は左）", arabic.map(LinkCard.card), side: .left),
            cardOnly("右から書く言語の見出し（画像は右）", arabic.map(LinkCard.card), side: .right),
            post("サーバーがまだカードを付けていない（リンク先だけ）", status(content: content)),
            post("サムネイルのないカード", status(content: content, card: card(image: nil))),
            post("見出しのないカード（URLを出す）", status(content: content, card: card(title: "", description: "", providerName: ""))),
            post("見出しと要約が長い", status(content: content, card: card(title: longText, description: longText, providerName: String(repeating: "長いサイトの名前", count: 4)))),
            post("ブーストされた投稿のカード", status(content: content, card: card(), rebloggedBy: booster)),
            post("閲覧注意のカード（覆った）", status(content: content, sensitive: true, card: card())),
            post("閲覧注意のカード（表示した）", status(content: content, sensitive: true, card: card()), revealsMedia: true),
            cardOnly("閲覧注意のカード（覆った、画像は右）", card().map(LinkCard.card), side: .right, coversImage: true),
            post("閲覧注意のカード（ぼかしの下地がない）", status(content: content, sensitive: true, card: card().map {
                PreviewCard(url: $0.url, title: $0.title, description: $0.description, type: $0.type, providerName: $0.providerName, image: $0.image, width: $0.width, height: $0.height)
            })),
            post("注意書きと閲覧注意のカード（開いた、画像は覆ったまま）", status(content: content, spoilerText: "ネタバレ", sensitive: true, card: card()), expandsSpoiler: true),
            post("閲覧注意の投稿の画像のないカード（覆わない）", status(content: content, sensitive: true, card: card(image: nil))),
            CatalogState(title: "サムネイルの読み込み中（ぼかし）") { CatalogFrame.bordered(pendingCard) },
        ]
    }

    @MainActor
    static func notificationStates() -> [CatalogState] {
        let notifications = TimelineViewController(texts: .notifications)
        notifications.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .notifications, myAccountID: nil))
        // メンションなどの投稿は通知を送った人が書き、お気に入りなどで再掲する投稿は自分が書いたもの。
        let mentioned = status(content: "<p>@me 通知の元になった投稿。</p>", account: booster)
        let mine = status(content: "<p>お気に入りやブーストをされた自分の投稿。</p>")
        func row(_ title: String, _ type: MastodonNotification.Kind, status: Status? = mentioned, account: Account = booster, expandsSpoiler: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let notification = MastodonNotification(id: UUID().uuidString, type: type, createdAt: .now.addingTimeInterval(-300), account: account, status: status)
                if expandsSpoiler, let status { notifications.toggleSpoiler(of: status) }
                @MainActor func configuration() -> any UIContentConfiguration {
                    notifications.contentConfiguration(for: notification, base: .cell())
                }
                let view = configuration().makeContentView()
                // 名前の前のアイコンは、届くまで灰色の枠で出す。一覧と同じく、届いたら組み立て直す。
                AppDependencies.avatarImages.addListener(owner: view) { [weak view] _ in
                    view?.configuration = configuration()
                }
                return CatalogFrame.bordered(view)
            }
        }
        let longBody = "<p>" + String(repeating: "お気に入りに登録された自分の投稿が長いときに、再掲する本文を何行で切るかを確かめるための文。", count: 4) + "</p>"
        return [
            row("メンション", .mention),
            row("メンション（画像つき）", .mention, status: status(content: "<p>@me 画像つきのメンション。</p>", account: booster, media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
            ])),
            row("メンション（リンクカードつき）", .mention, status: status(
                content: #"<p>@me <a href="https://news.example/articles/1">news.example/articles/1</a></p>"#,
                account: booster
            )),
            row("お気に入り（リンクカードは出さない）", .favourite, status: status(content: #"<p><a href="https://news.example/articles/1">news.example/articles/1</a></p>"#)),
            row("メンション（投稿が届かなかった）", .mention, status: nil),
            row("投稿の通知", .status),
            row("引用", .quote),
            row("ブースト", .reblog, status: mine),
            row("お気に入り", .favourite, status: mine),
            row("お気に入り（長い本文を切る）", .favourite, status: status(content: longBody)),
            row("お気に入り（注意書き、閉じた）", .favourite, status: status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            row("お気に入り（注意書き、開いた）", .favourite, status: status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ"), expandsSpoiler: true),
            row("メンション（注意書き、閉じた）", .mention, status: status(content: "<p>@me 注意書きの下の本文。</p>", account: booster, spoilerText: "ネタバレ")),
            row("メンション（フィルターの警告）", .mention, status: status(content: "<p>@me 警告で畳んだ本文。</p>", account: booster, filtered: [filter("ネタバレ", .warn, context: [.notifications])])),
            row("投稿の通知（フィルターで画像をぼかす）", .status, status: status(content: "<p>フィルターで画像をぼかした投稿。</p>", account: booster, media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], filtered: [filter("ネタバレ", .blur, context: [.notifications])])),
            row("お気に入り（画像2枚、ALTつき）", .favourite, status: status(content: "<p>画像を2枚添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 900, height: 1_600, color: .systemGreen, description: "緑の地に白い格子"),
            ])),
            row("お気に入り（画像が行に収まらず、横にスクロールする）", .favourite, status: status(content: "<p>画像を6枚添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
                Fixtures.attachment("b", width: 1_200, height: 900, color: .systemGreen),
                Fixtures.attachment("c", width: 1_200, height: 900, color: .systemOrange),
                Fixtures.attachment("d", width: 1_200, height: 900, color: .systemPurple),
                Fixtures.attachment("e", width: 1_200, height: 900, color: .systemRed),
                Fixtures.attachment("f", width: 1_200, height: 900, color: .systemTeal),
            ])),
            row("ブースト（閲覧注意の画像）", .reblog, status: status(content: "<p>閲覧注意の画像を添付した自分の投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            row("ブースト（本文のない画像だけの投稿）", .reblog, status: status(content: "", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemIndigo),
            ])),
            row("投票の終了", .poll, status: mine),
            row("ブーストした投稿の編集", .update, status: mine),
            row("引用した投稿の編集", .quotedUpdate, status: mine),
            row("フォロー", .follow, status: nil),
            row("フォロー（名前が長い）", .follow, status: nil, account: Fixtures.account(
                displayName: String(repeating: "とても長い名前", count: 4),
                acct: "a-very-long-account-name@subdomain.example.com"
            )),
            row("フォローリクエスト", .followRequest, status: nil),
            row("知らない種類", .other("admin.sign_up"), status: nil),
        ]
    }

    private static func status(
        content: String,
        account: Account = author,
        spoilerText: String = "",
        media: [MediaAttachment] = [],
        sensitive: Bool = false,
        card: PreviewCard? = nil,
        editedAt: Date? = nil,
        filtered: [FilterResult] = [],
        rebloggedBy: Account? = nil
    ) -> Status {
        let original = Status(
            id: UUID().uuidString,
            createdAt: .now.addingTimeInterval(-3_600),
            account: account,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media,
            sensitive: sensitive,
            card: card,
            filtered: filtered,
            editedAt: editedAt
        )
        guard let rebloggedBy else { return original }
        return Status(id: UUID().uuidString, createdAt: .now.addingTimeInterval(-600), account: rebloggedBy, content: "", spoilerText: "", url: nil, filtered: filtered, reblog: original)
    }

    private static func filter(_ title: String, _ action: FilterResult.Action, context: [FilterResult.Context] = [.home]) -> FilterResult {
        FilterResult(filter: FilterResult.Filter(id: title, title: title, context: context, filterAction: action), keywordMatches: [title])
    }
}
#endif
