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
        let home = TimelineViewController(texts: .home, refresh: {})
        home.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        // カタログのアカウントを自分として組む一覧。自分の投稿は、フィルターに一致しても折りたたまずに注記を出す。
        let mine = TimelineViewController(texts: .home, refresh: {})
        mine.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: author.id))
        mine.myAccountID = author.id
        /// - Parameters:
        ///   - expandsSpoiler: 注意書きを開く。フィルターの警告で折りたたんでいれば、警告を開く。
        ///   - isMine: カタログのアカウントを自分として組む。
        ///   - connection: 隣の行と線でつながっている形にする。
        func post(_ title: String, _ status: Status, isPinned: Bool = false, expandsSpoiler: Bool = false, isMine: Bool = false, connection: ReplyConnection = ReplyConnection()) -> CatalogState {
            CatalogState(title: title) {
                let timeline = isMine ? mine : home
                if expandsSpoiler { timeline.toggleSpoiler(of: status) }
                var configuration = timeline.contentConfiguration(for: status, isPinned: isPinned, base: .cell())
                configuration.replyConnection = connection
                return CatalogFrame.bordered(PostContentView(configuration: configuration))
            }
        }
        let longHandleAccount = Fixtures.account(displayName: "長いハンドルの人", acct: "a-very-long-account-name-for-replies@subdomain.example.com")
        let longSpoiler = String(repeating: "注意書きが長く、何行にもわたるときの折り返しを確かめる。", count: 4)
        return [
            post("短い本文", status(content: "<p>短い本文。</p>")),
            post("本文が短く、アイコンの方が下まで届く", status(content: "<p>あ</p>")),
            post("長い本文", status(content: "<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しと、行の高さを確かめるための文。", count: 5) + "</p>")),
            post("ブーストされた投稿", status(content: "<p>ブーストされた投稿。</p>", rebloggedBy: booster)),
            post("固定された投稿", status(content: "<p>プロフィールの上に固定された投稿。</p>"), isPinned: true),
            post("ほかの人への返信", status(content: "<p>返信の本文。</p>", account: booster, replyingTo: author)),
            post("ほかの人への返信（ハンドルが長い）", status(content: "<p>返信の本文。</p>", replyingTo: longHandleAccount)),
            post("投稿した人が続けて書いた投稿", status(content: "<p>続けて書いた本文。</p>", replyingTo: author)),
            post("自分への返信", status(content: "<p>自分への返信の本文。</p>", account: booster, replyingTo: author), isMine: true),
            post("返信先のハンドルが分からない返信（メンションを消した）", status(content: "<p>メンションのない返信。</p>", account: booster, replyingTo: author, mentionsReplyTarget: false)),
            post("返信をブーストした投稿（ブーストの行を出し、ラベルは出さない）", status(content: "<p>ブーストされた返信。</p>", rebloggedBy: booster, replyingTo: author)),
            post("上と下の行と線でつながった返信", status(content: "<p>線でつながった返信。</p>", replyingTo: author), connection: ReplyConnection(above: true, below: true)),
            post("下の行とだけ線でつながった、本文の長い返信", status(content: "<p>" + String(repeating: "本文が長く、線がアイコンの下から行の下端まで伸びることを確かめる文。", count: 3) + "</p>", account: booster, replyingTo: author), connection: ReplyConnection(below: true)),
            post("お気に入り済み", status(content: "<p>お気に入りした投稿。</p>", favourited: true)),
            post("ブースト済み", status(content: "<p>ブーストした投稿。</p>", reblogged: true)),
            post("お気に入りとブースト済み（真ん中で色が変わる）", status(content: "<p>お気に入りもブーストもした投稿。</p>", favourited: true, reblogged: true)),
            post("お気に入りとブースト済みで、本文が短い", status(content: "<p>あ</p>", favourited: true, reblogged: true)),
            post("お気に入りとブースト済みで、画像が下の端にある", status(content: "<p>画像の後ろに光が隠れる投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemTeal),
            ], favourited: true, reblogged: true)),
            post("ほかの人がブーストした投稿に、お気に入り済み", status(content: "<p>ブーストで流れてきた投稿。</p>", favourited: true, rebloggedBy: booster)),
            post("注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            post("注意書き（開いた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ"), expandsSpoiler: true),
            post("注意書きが長い（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: longSpoiler)),
            post("注意書きと閲覧注意の画像（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true)),
            post("注意書きと閲覧注意の画像（開いた、画像はぼかしたまま）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true), expandsSpoiler: true),
            post("注意書きと画像だけで本文がない（開いた）", status(content: "", spoilerText: "ネタバレ", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemTeal),
            ], sensitive: true), expandsSpoiler: true),
            post("ブーストされた注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", rebloggedBy: booster)),
            post("フィルターの警告", status(content: "<p>警告で折りたたんだ本文。</p>", filtered: [filter("ネタバレ", .warn)])),
            post("フィルターの警告（名前が長い、2つに一致した）", status(content: "<p>警告で折りたたんだ本文。</p>", filtered: [filter(longFilterTitle, .warn), filter("ネタバレ", .warn)])),
            post("フィルターの警告と画像とリンクカード（どれも出さない）", status(
                content: #"<p>警告で折りたたんだ本文。<a href="https://news.example/articles/1">news.example/articles/1</a></p>"#,
                media: [Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange)],
                filtered: [filter("ネタバレ", .warn)]
            )),
            post("フィルターの警告と注意書き（閉じた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", filtered: [filter("ネタバレ", .warn)])),
            post("フィルターの警告と注意書き（警告を開いた）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", filtered: [filter("ネタバレ", .warn)]), expandsSpoiler: true),
            post("ブーストされたフィルターの警告", status(content: "<p>警告で折りたたんだ本文。</p>", filtered: [filter("ネタバレ", .warn)], rebloggedBy: booster)),
            post("フィルターで画像をぼかす", status(content: "<p>フィルターで画像をぼかした投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], filtered: [filter("ネタバレ", .blur)])),
            post("フィルターで画像をぼかす（閲覧注意も付いた、名前が長い）", status(content: "<p>フィルターで画像をぼかした投稿。</p>", media: [
                Fixtures.attachment("a", width: 1_600, height: 900, color: .systemOrange),
            ], sensitive: true, filtered: [filter(longFilterTitle, .blur)])),
            post("自分の投稿がフィルターに一致した（折りたたまずに注記を出す）", status(content: "<p>フィルターした話題に自分で触れた投稿。</p>", filtered: [filter("ネタバレ", .hide)]), isMine: true),
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
                content: "<p>名前が1行に収まらず、編集済みのアイコンも付く投稿。</p>",
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com"),
                editedAt: .now.addingTimeInterval(-60)
            )),
            post("ひかえめな公開", status(content: "<p>ひかえめな公開の投稿。</p>", visibility: .unlisted)),
            post("フォロワーのみ", status(content: "<p>フォロワーのみの投稿。</p>", visibility: .private)),
            post("メンションした相手のみ", status(content: "<p>メンションした相手のみの投稿。</p>", visibility: .direct)),
            post("フォロワーのみで編集され、名前が長い", status(
                content: "<p>名前が1行に収まらず、公開範囲の記号と編集済みのアイコンも付く投稿。</p>",
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com"),
                editedAt: .now.addingTimeInterval(-60),
                visibility: .private
            )),
            post("アイコンがない", status(content: "<p>アイコンのURLがないアカウントの投稿。</p>", account: Fixtures.account(acct: "noavatar@example.com", avatar: nil))),
        ]
    }

    /// 添付ファイルを本文の右に小さく出す並べ方の投稿。アプリの設定は変えず、この並べ方にした設定で組む。
    /// 数による重なり、本文の長さとの高さの比べ合い、ぼかし、下に並ぶ部品との重なりを見比べる。
    @MainActor
    static func mediaBesideStates() -> [CatalogState] {
        let suiteName = "net.mizle.scia.catalog.mediaBeside"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("カタログのUserDefaultsを作れない")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.mediaArrangement = .besideBody
        let home = TimelineViewController(texts: .home, refresh: {}, settings: settings)
        home.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        let mine = TimelineViewController(texts: .home, refresh: {}, settings: settings)
        mine.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: author.id))
        mine.myAccountID = author.id
        // 「写真を傾ける」をオフにした設定の一覧。
        let straightSuiteName = "net.mizle.scia.catalog.mediaBeside.straight"
        guard let straightDefaults = UserDefaults(suiteName: straightSuiteName) else {
            preconditionFailure("カタログのUserDefaultsを作れない")
        }
        straightDefaults.removePersistentDomain(forName: straightSuiteName)
        let straightSettings = AppSettings(defaults: straightDefaults)
        straightSettings.mediaArrangement = .besideBody
        straightSettings.tiltsStackedPhotos = false
        let straight = TimelineViewController(texts: .home, refresh: {}, settings: straightSettings)
        straight.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        func post(_ title: String, _ status: Status, expandsSpoiler: Bool = false, isMine: Bool = false, isStraight: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let timeline = isStraight ? straight : isMine ? mine : home
                if expandsSpoiler { timeline.toggleSpoiler(of: status) }
                return CatalogFrame.bordered(PostContentView(configuration: timeline.contentConfiguration(for: status, base: .cell())))
            }
        }
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink]
        func images(_ count: Int) -> [MediaAttachment] {
            (0..<count).map { Fixtures.attachment("\($0)", width: 1_200, height: 900, color: colors[$0 % colors.count], label: "\($0 + 1)") }
        }
        let longText = "<p>" + String(repeating: "本文が長く、サムネイルの右をあけて何行にもわたって折り返すことを確かめる文。", count: 4) + "</p>"
        let link = "https://news.example/articles/2026/10/link-card"
        let card = URL(string: link).map {
            PreviewCard(url: $0, title: "記事の見出し", description: "記事の要約が入る。", type: .link, providerName: "News Example", image: Fixtures.imageURL(width: 400, height: 225, color: .systemIndigo), width: 400, height: 225, blurhash: Fixtures.blurhash)
        }
        return [
            post("画像1つ、本文が1行（サムネイルの分だけ行が伸びる）", status(content: "<p>短い本文。</p>", media: images(1))),
            post("画像1つ、本文が長い", status(content: longText, media: images(1))),
            post("画像2つ", status(content: "<p>画像を2つ添付した投稿。</p>", media: images(2))),
            post("画像3つ", status(content: "<p>画像を3つ添付した投稿。</p>", media: images(3))),
            post("画像4つ（4つ目は描かない）", status(content: "<p>画像を4つ添付した投稿。</p>", media: images(4))),
            post("本文がなく、画像2つ", status(content: "", media: images(2))),
            post("縦長の画像1つ（正方形に切り抜く）", status(content: "<p>縦長の画像。</p>", media: [Fixtures.attachment("tall", width: 600, height: 1_800, color: .systemTeal, label: "縦長")])),
            post("動画と、代替テキストのある画像（バッジは手前だけ）", status(content: "<p>動画と画像。</p>", media: [
                Fixtures.attachment("video", type: .video, width: 1_600, height: 900, color: .systemRed),
                Fixtures.attachment("described", width: 1_200, height: 900, color: .systemGreen, description: "緑の地に白い格子"),
            ])),
            post("代替テキストのある画像が手前", status(content: "<p>代替テキストのある画像。</p>", media: [
                Fixtures.attachment("described", width: 1_200, height: 900, color: .systemGreen, description: "緑の地に白い格子"),
                Fixtures.attachment("plain", width: 1_200, height: 900, color: .systemBlue),
            ])),
            post("閲覧注意の画像2つ", status(content: "<p>閲覧注意の画像を添付した投稿。</p>", media: images(2), sensitive: true)),
            post("フィルターで画像をぼかす（名前が長い）", status(content: "<p>フィルターで画像をぼかした投稿。</p>", media: images(2), filtered: [filter(longFilterTitle, .blur)])),
            post("注意書き（閉じた、サムネイルは出さない）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: images(2))),
            post("注意書き（開いた、サムネイルは本文の横）", status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ", media: images(2)), expandsSpoiler: true),
            post("注意書きと画像だけで本文がない（開いた）", status(content: "", spoilerText: "ネタバレ", media: images(1)), expandsSpoiler: true),
            post("画像とリンクカード（カードは両方より下）", status(
                content: #"<p>記事を読んだ。<a href="\#(link)">news.example/articles/2026/10/link-card</a></p>"#,
                media: images(2),
                card: card
            )),
            post("自分の投稿がフィルターに一致した（注記は両方より下）", status(content: "<p>フィルターした話題に自分で触れた投稿。</p>", media: images(2), filtered: [filter("画像", .warn)]), isMine: true),
            post("名前が長く、本文が長い", status(
                content: longText,
                account: Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com"),
                media: images(3)
            )),
            post("ブーストされた投稿", status(content: "<p>ブーストされた投稿。</p>", media: images(2), rebloggedBy: booster)),
            post("傾けない、画像1つ", status(content: "<p>写真を傾けない設定。</p>", media: images(1)), isStraight: true),
            post("傾けない、画像2つ", status(content: "<p>写真を傾けない設定。</p>", media: images(2)), isStraight: true),
            post("傾けない、画像4つ（奥ほど小さく下からのぞく）", status(content: "<p>写真を傾けない設定。</p>", media: images(4)), isStraight: true),
            post("傾けない、画像5つ（5つ目は描かない）", status(content: "<p>写真を傾けない設定。</p>", media: images(5)), isStraight: true),
        ]
    }

    /// リンクカードの付いた投稿。サーバーのカードが後から届いても行の高さが変わらないことを、カードとリンク先だけのカードを並べて見比べる。
    @MainActor
    static func linkCardStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home, refresh: {})
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
            pendingCard.apply(LinkCardView.Content(card: .card(loading), padding: home.settings.value(of: AppearanceCatalog.linkCardPadding), transitionDuration: 0, thumbnailSide: .left, typography: PostTypography(settings: home.settings)))
        }
        // 画像の位置の設定によらず、左右と文字の方向の組み合わせを並べるため、カードだけを置く。
        func cardOnly(_ title: String, _ linkCard: LinkCard?, side: LinkCardThumbnailSide, coversImage: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let view = LinkCardView(store: AppDependencies.mediaImages)
                if let linkCard {
                    view.apply(LinkCardView.Content(card: linkCard, padding: home.settings.value(of: AppearanceCatalog.linkCardPadding), transitionDuration: 0, thumbnailSide: side, typography: PostTypography(settings: home.settings), coversImage: coversImage))
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
            post("閲覧注意のカード（ぼかした）", status(content: content, sensitive: true, card: card())),
            post("閲覧注意のカード（表示した）", status(content: content, sensitive: true, card: card()), revealsMedia: true),
            cardOnly("閲覧注意のカード（ぼかした、画像は右）", card().map(LinkCard.card), side: .right, coversImage: true),
            post("閲覧注意のカード（ぼかしの下地がない）", status(content: content, sensitive: true, card: card().map {
                PreviewCard(url: $0.url, title: $0.title, description: $0.description, type: $0.type, providerName: $0.providerName, image: $0.image, width: $0.width, height: $0.height)
            })),
            post("注意書きと閲覧注意のカード（開いた、画像はぼかしたまま）", status(content: content, spoilerText: "ネタバレ", sensitive: true, card: card()), expandsSpoiler: true),
            post("閲覧注意の投稿の画像のないカード（ぼかさない）", status(content: content, sensitive: true, card: card(image: nil))),
            CatalogState(title: "サムネイルの読み込み中（ぼかし）") { CatalogFrame.bordered(pendingCard) },
        ]
    }

    @MainActor
    static func notificationStates() -> [CatalogState] {
        let notifications = TimelineViewController(texts: .notifications, refresh: {})
        notifications.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .notifications, myAccountID: nil))
        // メンションなどの投稿は通知を送った人が書き、お気に入りなどで再掲する投稿は自分が書いたもの。
        let mentioned = status(content: "<p>@me 通知の元になった投稿。</p>", account: booster)
        let mine = status(content: "<p>お気に入りやブーストをされた自分の投稿。</p>")
        /// - Parameter group: まとめた通知にするなら、並べる人（先頭がいちばん新しい人）と、まとまりの人数。
        func row(_ title: String, _ type: MastodonNotification.Kind, status: Status? = mentioned, account: Account = booster, group: (accounts: [Account], count: Int)? = nil, expandsSpoiler: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let id = UUID().uuidString
                let notification = MastodonNotification(
                    id: id, type: type, createdAt: .now.addingTimeInterval(-300), account: group?.accounts.first ?? account, status: status,
                    groupKey: "\(type.rawValue)-\(id)", notificationsCount: group?.count ?? 1, sampleAccounts: group?.accounts
                )
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
        let colors: [UIColor] = [.systemPink, .systemGreen, .systemPurple, .systemTeal, .systemOrange, .systemBlue, .systemRed, .systemIndigo]
        let people = colors.enumerated().map { index, color in
            Fixtures.account(displayName: "人\(index + 1)", acct: "person\(index + 1)@example.com", avatar: Fixtures.imageURL(width: 200, height: 200, color: color))
        }
        let longNamed = Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com")
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
            row("引用", .quote, status: status(content: "<p>自分の投稿を引用した投稿。</p>", account: booster, quote: Quote(state: "accepted", quotedStatus: mine))),
            row("お気に入り（引用した自分の投稿。囲みは出さず1行にする）", .favourite, status: status(content: "<p>引用した自分の投稿。</p>", quote: Quote(state: "accepted", quotedStatus: mentioned))),
            row("ブースト", .reblog, status: mine),
            row("お気に入り", .favourite, status: mine),
            row("お気に入り（自分でもお気に入りとブースト済み）", .favourite, status: status(content: "<p>自分でもお気に入りとブーストをした自分の投稿。</p>", favourited: true, reblogged: true)),
            row("メンション（お気に入り済み）", .mention, status: status(content: "<p>@me お気に入りしたメンション。</p>", account: booster, favourited: true)),
            row("お気に入り（長い本文を切る）", .favourite, status: status(content: longBody)),
            row("お気に入り（長い本文を切る、画像つき）", .favourite, status: status(content: longBody, media: [
                Fixtures.attachment("a", width: 1_200, height: 900, color: .systemBlue),
            ])),
            row("お気に入り（注意書き、閉じた）", .favourite, status: status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ")),
            row("お気に入り（注意書き、開いた）", .favourite, status: status(content: "<p>注意書きの下の本文。</p>", spoilerText: "ネタバレ"), expandsSpoiler: true),
            row("メンション（注意書き、閉じた）", .mention, status: status(content: "<p>@me 注意書きの下の本文。</p>", account: booster, spoilerText: "ネタバレ")),
            row("メンション（フィルターの警告）", .mention, status: status(content: "<p>@me 警告で折りたたんだ本文。</p>", account: booster, filtered: [filter("ネタバレ", .warn, context: [.notifications])])),
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
            row("投票の終了（結果を出し、押せない）", .poll, status: status(content: "<p>締め切った自分の投票。</p>", poll: PollCatalog.endedPoll)),
            row("ブーストした投稿の編集", .update, status: mine),
            row("引用した投稿の編集", .quotedUpdate, status: mine),
            row("フォロー", .follow, status: nil),
            row("フォロー（名前が長い）", .follow, status: nil, account: Fixtures.account(
                displayName: String(repeating: "とても長い名前", count: 4),
                acct: "a-very-long-account-name@subdomain.example.com"
            )),
            row("まとめたお気に入り（2人）", .favourite, status: mine, group: (Array(people.prefix(2)), 2)),
            row("まとめたお気に入り（並べた人より多い）", .favourite, status: mine, group: (Array(people.prefix(3)), 12)),
            row("まとめたブースト（8人を並べ、人数が大きい）", .reblog, status: mine, group: (people, 1_234)),
            row("まとめたお気に入り（名前が長い）", .favourite, status: mine, group: ([longNamed] + people.prefix(2), 3)),
            row("まとめたフォロー", .follow, status: nil, group: (Array(people.prefix(4)), 4)),
            row("フォローリクエスト", .followRequest, status: nil),
            row("知らない種類", .other("admin.sign_up"), status: nil),
        ]
    }

    /// 投稿の中の引用。引用元を出せないときの`state`ごとの文言と、囲みの中の注意書き、フィルター、入れ子、長さの違いを並べる。決まりは`docs/quote.md`。
    @MainActor
    static func quoteStates() -> [CatalogState] {
        let home = TimelineViewController(texts: .home, refresh: {})
        home.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        /// - Parameters:
        ///   - expandsQuotedSpoiler: 引用元の注意書きを開く。フィルターの警告で折りたたんでいれば、警告を開く。
        ///   - revealsQuote: ブロックかミュートしている人の引用元を開く。
        func post(_ title: String, _ quote: Quote, content: String = "<p>引用した投稿の本文。</p>", spoilerText: String = "", expandsQuotedSpoiler: Bool = false, revealsQuote: Bool = false) -> CatalogState {
            CatalogState(title: title) {
                let status = status(content: content, spoilerText: spoilerText, quote: quote)
                if expandsQuotedSpoiler, let quoted = quote.quotedStatus { home.toggleSpoiler(of: quoted) }
                if revealsQuote { home.quoteReveals.reveal(status) }
                return CatalogFrame.bordered(PostContentView(configuration: home.contentConfiguration(for: status, base: .cell())))
            }
        }
        func quoted(content: String = "<p>引用元の本文。</p>", account: Account = booster, spoilerText: String = "", media: [MediaAttachment] = [], sensitive: Bool = false, poll: Poll? = nil, filtered: [FilterResult] = [], quote: Quote? = nil) -> Status {
            status(content: content, account: account, spoilerText: spoilerText, media: media, sensitive: sensitive, poll: poll, filtered: filtered, quote: quote)
        }
        func accepted(_ status: Status) -> Quote {
            Quote(state: "accepted", quotedStatus: status)
        }
        let image = Fixtures.attachment("a", width: 1_600, height: 900, color: .systemTeal)
        let longNamed = Fixtures.account(displayName: String(repeating: "とても長い名前", count: 4), acct: "a-very-long-account-name@subdomain.example.com")
        let longBody = "<p>" + String(repeating: "引用元の本文が長いときも、行数で切らずに全文を出すことを確かめる文。", count: 4) + "</p>"
        return [
            post("引用元の本文だけ", accepted(quoted())),
            post("引用元に画像", accepted(quoted(media: [image]))),
            post("引用元の本文がなく画像だけ", accepted(quoted(content: "", media: [image]))),
            post("引用元の本文が長い（切らない）", accepted(quoted(content: longBody))),
            post("引用元の名前とハンドルが長い", accepted(quoted(account: longNamed))),
            post("引用元に投票（1行にする）", accepted(quoted(poll: PollCatalog.endedPoll))),
            post("引用元が閲覧注意の画像", accepted(quoted(media: [image], sensitive: true))),
            post("引用元に注意書き（閉じた）", accepted(quoted(spoilerText: "ネタバレ", media: [image], sensitive: true))),
            post("引用元に注意書き（開いた）", accepted(quoted(spoilerText: "ネタバレ", media: [image], sensitive: true)), expandsQuotedSpoiler: true),
            post("引用した投稿に注意書き（閉じて、囲みごと隠す）", accepted(quoted()), spoilerText: "引用のネタバレ"),
            post("引用元がフィルターの警告に一致", accepted(quoted(filtered: [filter("ネタバレ", .warn)]))),
            post("引用元がフィルターで画像をぼかすに一致", accepted(quoted(media: [image], filtered: [filter("ネタバレ", .blur)]))),
            post("引用元がフィルターの「隠す」に一致", accepted(quoted(filtered: [filter("ネタバレ", .hide)]))),
            post("引用元がさらに引用している（押せる）", accepted(quoted(quote: Quote(state: "accepted", quotedStatusID: "1")))),
            post("引用元がさらに引用している（承認待ちで押せない）", accepted(quoted(quote: Quote(state: "pending")))),
            post("引用元に投票があり、さらに引用している", accepted(quoted(poll: PollCatalog.endedPoll, quote: Quote(state: "accepted", quotedStatusID: "1")))),
            post("承認待ち", Quote(state: "pending")),
            post("断られた", Quote(state: "rejected")),
            post("取り消された", Quote(state: "revoked")),
            post("削除された", Quote(state: "deleted")),
            post("見る権限がない", Quote(state: "unauthorized")),
            post("知らないstate", Quote(state: "a_future_state")),
            post("ブロックしている人（押すと開く）", Quote(state: "blocked_account", quotedStatus: quoted())),
            post("ブロックしているドメインの人", Quote(state: "blocked_domain", quotedStatus: quoted())),
            post("ミュートしている人", Quote(state: "muted_account", quotedStatus: quoted())),
            post("ミュートしている人（開いた）", Quote(state: "muted_account", quotedStatus: quoted()), revealsQuote: true),
            post("引用した投稿の本文がない", accepted(quoted()), content: ""),
        ]
    }

    /// お気に入りした人などの一覧の行。名前とハンドルの長さで崩れないかを見る。
    @MainActor
    static func accountStates() -> [CatalogState] {
        let list = TimelineViewController(texts: .accountList(.favouritedBy("catalog")), refresh: {})
        func row(_ title: String, _ account: Account) -> CatalogState {
            CatalogState(title: title) {
                CatalogFrame.bordered(list.accountConfiguration(for: account, base: .cell()).makeContentView())
            }
        }
        return [
            row("ふつう", booster),
            row("名前とハンドルが長い", Fixtures.account(
                displayName: String(repeating: "とても長い名前", count: 4),
                acct: "a-very-long-account-name@subdomain.example.com"
            )),
            row("表示名がない（ユーザー名を出す）", Fixtures.account(displayName: "", acct: "noname@example.com")),
        ]
    }

    private static func status(
        content: String,
        account: Account = author,
        spoilerText: String = "",
        media: [MediaAttachment] = [],
        sensitive: Bool = false,
        poll: Poll? = nil,
        card: PreviewCard? = nil,
        editedAt: Date? = nil,
        visibility: Status.Visibility = .public,
        filtered: [FilterResult] = [],
        favourited: Bool = false,
        reblogged: Bool = false,
        rebloggedBy: Account? = nil,
        replyingTo replyTarget: Account? = nil,
        mentionsReplyTarget: Bool = true,
        quote: Quote? = nil
    ) -> Status {
        let mentions = replyTarget.map { [Mention(id: $0.id, username: $0.username, url: nil, acct: $0.acct)] } ?? []
        let original = Status(
            id: UUID().uuidString,
            createdAt: .now.addingTimeInterval(-3_600),
            account: account,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mentions: mentionsReplyTarget ? mentions : [],
            mediaAttachments: media,
            sensitive: sensitive,
            visibility: visibility,
            inReplyToId: replyTarget.map { _ in UUID().uuidString },
            inReplyToAccountId: replyTarget?.id,
            poll: poll,
            card: card,
            quote: quote,
            filtered: filtered,
            editedAt: editedAt,
            favourited: favourited,
            reblogged: reblogged
        )
        guard let rebloggedBy else { return original }
        return Status(id: UUID().uuidString, createdAt: .now.addingTimeInterval(-600), account: rebloggedBy, content: "", spoilerText: "", url: nil, filtered: filtered, reblog: original)
    }

    private static func filter(_ title: String, _ action: FilterResult.Action, context: [FilterResult.Context] = [.home]) -> FilterResult {
        FilterResult(filter: FilterResult.Filter(id: title, title: title, context: context, filterAction: action), keywordMatches: [title])
    }
}
#endif
