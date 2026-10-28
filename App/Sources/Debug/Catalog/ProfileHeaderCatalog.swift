#if DEBUG
import Foundation
import SciaCore
import UIKit

/// プロフィールの頭に置く、アカウントの情報と一覧の切り替え（`ProfileHeaderView`）の状態。
/// フォローの操作は、押すと次の状態へ進めるだけにし、サーバーには送らない。
enum ProfileHeaderCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let fullAccount = Fixtures.account(
        displayName: "カタログのアカウント",
        acct: "catalog",
        header: Fixtures.imageURL(width: 1_500, height: 500, color: .systemIndigo),
        note: "<p>自己紹介の文。複数の行にわたるときの折り返しと、<a href=\"https://example.com/tags/scia\">#scia</a> のようなリンクを確かめる。</p>",
        fields: [
            Account.Field(name: "Webサイト", value: "<a href=\"https://example.com\">example.com</a>", verifiedAt: .now),
            Account.Field(name: "場所", value: "東京"),
            // サーバーが30字で縮めた形のURL。補足情報では全体を出して折り返し、確認済みのチェックマークは末尾に付く。
            Account.Field(
                name: "長いリンク",
                value: "<a href=\"https://example.com/users/catalog/very/long/path/to/the/page\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">example.com/users/catalog/very</span><span class=\"invisible\">/long/path/to/the/page</span></a>",
                verifiedAt: .now
            ),
        ]
    )

    /// 固定された投稿の棚に並べる、形の違うカード。長い本文、添付ファイル付き、閲覧注意の警告、閲覧注意の添付ファイル、短い本文。
    private static let pinnedStatuses: [Status] = {
        func status(_ id: String, _ content: String, spoilerText: String = "", media: [MediaAttachment] = [], sensitive: Bool = false, daysAgo: Double) -> Status {
            Status(
                id: "pinned-\(id)",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000 - daysAgo * 86_400),
                account: fullAccount,
                content: content,
                spoilerText: spoilerText,
                url: nil,
                mediaAttachments: media,
                sensitive: sensitive,
                pinned: true
            )
        }
        return [
            status("long", "<p>固定された投稿の本文が長いときは、5行で切って末尾を省く。カードの高さは一番背の高いカードに揃うので、短い本文のカードも同じ高さになる。ここから先は省かれる部分の文。ここから先は省かれる部分の文。</p>", daysAgo: 1),
            status("media", "<p>添付ファイルのある投稿は、最初の1枚を右に小さく出す。<a href=\"https://example.com\">example.com</a></p>", media: [Fixtures.attachment("pinned-media", width: 1_200, height: 800, color: .systemOrange)], daysAgo: 30),
            status("warning", "<p>警告の下の本文。カードには出さない。</p>", spoilerText: "閲覧注意の警告の文", media: [Fixtures.attachment("pinned-warning", width: 800, height: 800)], daysAgo: 120),
            status("sensitive", "<p>添付ファイルだけを閲覧注意にした投稿。カードでは添付ファイルを出さない。</p>", media: [Fixtures.attachment("pinned-sensitive", width: 800, height: 800, color: .systemRed)], sensitive: true, daysAgo: 400),
            status("short", "<p>短い本文</p>", daysAgo: 800),
        ]
    }()

    /// サーバーのフィルターに一致した、添付ファイル付きの投稿。1つ目は警告、2つ目は添付ファイルのぼかし。
    private static let filteredStatuses: [Status] = [
        ("warn", "ネタバレ", FilterResult.Action.warn, UIColor.systemRed),
        ("blur", "写真", .blur, .systemBlue),
    ].map { id, title, action, color in
        Status(
            id: "filtered-\(id)",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            account: fullAccount,
            content: "<p>フィルターに一致した投稿の本文。棚には出さない。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: [Fixtures.attachment("filtered-\(id)", width: 800, height: 800, color: color)],
            filtered: [FilterResult(filter: FilterResult.Filter(id: id, title: title, context: [.account], filterAction: action))]
        )
    }

    /// 3行に収まらない自己紹介。「さらに表示」を押すと、その場で全文に広がる。
    private static let longNoteAccount = Fixtures.account(
        displayName: "長い自己紹介のアカウント",
        acct: "long@remote.example",
        header: Fixtures.imageURL(width: 1_500, height: 500, color: .systemOrange),
        note: "<p>1段落目。自己紹介が長いときは3行で切り、「さらに表示」でその場で全文に広げる。</p><p>2段落目。ここから先は、切ったときには見えない。</p><p>3段落目。広げると、下の内容だけが下がり、上の棚は動かない。</p>",
        fields: [
            Account.Field(name: "Webサイト", value: "<a href=\"https://example.com\">example.com</a>", verifiedAt: .now),
            Account.Field(name: "場所", value: "東京"),
            Account.Field(name: "好きなもの", value: "写真"),
        ]
    )

    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "フォローしていない（ヘッダー画像、自己紹介、確認済みのリンク）") { header(fullAccount, .notFollowing(locked: false)) },
            CatalogState(title: "フォローしていない承認制のアカウント") {
                header(Fixtures.account(acct: "locked", note: "<p>承認制</p>", locked: true), .notFollowing(locked: true))
            },
            CatalogState(title: "フォローの承認を待っている") { header(Fixtures.account(acct: "locked", locked: true), .requested) },
            CatalogState(title: "フォロー中で、フォローされている") { header(fullAccount, .following, followedBy: true) },
            CatalogState(title: "明るいヘッダー画像で、フォローされている（「フォローされています」の読みやすさ）") {
                header(Fixtures.account(acct: "bright", header: Fixtures.imageURL(width: 1_500, height: 500, color: .white)), .notFollowing(locked: false), followedBy: true)
            },
            CatalogState(title: "ヘッダー画像なしで、承認制のアカウントにフォローされている") {
                // ヘッダー画像を設定していないアカウントには透明な画像が返り、下地の色が見える。読めない画像を渡して、同じ見え方にする。
                header(Fixtures.account(acct: "locked", header: URL(string: "data:image/png;base64,"), locked: true), .notFollowing(locked: true), followedBy: true)
            },
            CatalogState(title: "フォローを変えている途中") { header(fullAccount, .following, isChangingFollow: true) },
            CatalogState(title: "関係を読み込む前") { header(fullAccount, .unknown) },
            CatalogState(title: "関係を読み込むのが長引いている（ボタンの中のインジケータ）") { header(fullAccount, .unknown, showsRelationshipActivity: true) },
            CatalogState(title: "関係を読み込めなかった（再試行を押すと読み込み直す途中になる）") { header(fullAccount, .loadFailed) },
            CatalogState(title: "読み込めなかった関係を読み込み直している途中") { header(fullAccount, .loadFailed, isReloadingRelationship: true) },
            CatalogState(title: "自分（ボタンなし）、ヘッダー画像・自己紹介・補足情報・アイコンなし") {
                header(Fixtures.account(acct: "me", avatar: nil), .myself)
            },
            CatalogState(title: "ほかのサーバーのbot") {
                header(Fixtures.account(displayName: "ほかのサーバーのbot", acct: "bot@remote.example", bot: true), .notFollowing(locked: false))
            },
            CatalogState(title: "メディアのタブ、角丸のアイコン") { header(fullAccount, .following, tab: .media, avatarShape: .roundedSquare) },
            CatalogState(title: "固定された投稿の棚（長い本文、添付ファイル、閲覧注意の警告、閲覧注意の添付ファイル、短い本文）") {
                header(fullAccount, .following, pinned: pinnedStatuses)
            },
            CatalogState(title: "固定された投稿が1件") { header(fullAccount, .following, pinned: Array(pinnedStatuses.prefix(1))) },
            CatalogState(title: "フィルターに一致した固定された投稿（1つ目が警告、2つ目がぼかし）") {
                header(fullAccount, .following, pinned: filteredStatuses)
            },
            CatalogState(title: "3行に収まらない自己紹介と補足情報3つ、ほかのサーバー（「さらに表示」で広がる）") {
                header(longNoteAccount, .notFollowing(locked: false))
            },
            CatalogState(title: "自分にしか見えないメモ（自己紹介と補足情報のカードの間）") {
                header(fullAccount, .following, privateNote: "前にオフ会で会った人")
            },
            CatalogState(title: "長いメモで、自己紹介なし（改行と折り返し）") {
                header(
                    Fixtures.account(acct: "memo@remote.example"),
                    .notFollowing(locked: false),
                    privateNote: "1行目。メモは書いたままの平文で、リンクやメンションにしない。https://example.com @catalog #scia\n2行目。長いメモは省かずに全文を出し、幅に合わせて折り返す。ここから先も折り返して続く文。"
                )
            },
            CatalogState(title: "投稿の絞り込みを変えた（返信を含む）") {
                header(fullAccount, .following, postsFilter: ProfilePostsFilter(showsReplies: true, showsBoosts: true))
            },
        ]
    }

    /// カードの色を確かめるアカウント。リンクの色を見比べるため、自己紹介にハッシュタグとメンションとURLを、補足情報に確認済みと確認していないリンクを入れる。
    /// 自己紹介は3行に収まらない長さにし、画面のティントカラーで描く「さらに表示」も出す。
    /// ヘッダー画像は、どの色でも同じものを1回だけ作る。状態ごとに画像を描いてJPEGに書き出すと、32のヘッダーの分だけ開くのが重くなるため。
    private static let accentBanner = Fixtures.imageURL(width: 600, height: 200, color: .systemGray4)

    private static func accentAccount(avatar: URL?) -> Account {
        Fixtures.account(
            displayName: "カードの色",
            acct: "accent@remote.example",
            avatar: avatar,
            header: accentBanner,
            note: "<p>本文の中の<a href=\"https://example.com/tags/scia\">#scia</a>と<a href=\"https://example.com/@catalog\">@catalog</a>、<a href=\"https://example.com\">example.com</a>の色。</p><p>2段落目。3行に収まらないので、「さらに表示」が出る。</p><p>3段落目。</p>",
            fields: [
                Account.Field(name: "確認済みのリンク", value: "<a href=\"https://example.com\">example.com</a>", verifiedAt: .now),
                Account.Field(name: "確認していないリンク", value: "<a href=\"https://example.org\">example.org</a>"),
                Account.Field(name: "文字だけ", value: "東京"),
            ]
        )
    }

    /// カードの色を確かめるアイコンの色。
    static let accentColors: [(name: String, color: UIColor)] = [
        ("オレンジ", UIColor(red: 1, green: 0.55, blue: 0, alpha: 1)),
        ("黄色", UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)),
        ("赤", UIColor(red: 0.85, green: 0.1, blue: 0.15, alpha: 1)),
        ("淡い桃色", UIColor(red: 1, green: 0.75, blue: 0.8, alpha: 1)),
        ("紫", UIColor(red: 0.4, green: 0.25, blue: 1, alpha: 1)),
        ("青", UIColor(red: 0, green: 0.45, blue: 1, alpha: 1)),
        ("紺", UIColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)),
        ("青緑", UIColor(red: 0.1, green: 0.6, blue: 0.58, alpha: 1)),
        ("緑", UIColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)),
        ("茶色", UIColor(red: 0.45, green: 0.3, blue: 0.2, alpha: 1)),
        ("白（灰色のテーマ）", UIColor(white: 1, alpha: 1)),
        ("灰色（灰色のテーマ）", UIColor(white: 0.5, alpha: 1)),
        ("黒（灰色のテーマ）", UIColor(white: 0.05, alpha: 1)),
    ]

    /// カードの色で変わるフォローのボタンの状態。
    static let accentFollowStates: [(name: String, state: FollowState)] = [
        ("していない", .notFollowing(locked: false)),
        ("フォロー中", .following),
        ("リクエスト中", .requested),
        ("自分", .myself),
    ]

    /// アイコンの色とフォローの状態を選び、カードの色、文字とリンクの色、フォローのボタン、画面のティントカラーを、ライトとダークで並べる。
    /// 実物と同じく、アイコンの画像から色を作り、チューニングの値で付ける。
    /// 組み合わせを全部並べず、選んだ1つだけを出す。ヘッダーを32並べると、Auto Layoutが1つの画面の制約をまとめて解くため、開くのに20秒以上かかったため。
    @MainActor
    static func accentStates() -> [CatalogState] {
        [CatalogState(title: "アイコンの色とボタンの状態を選ぶ（上がライト、下がダーク）") { AccentPicker() }]
    }

    /// 選んだ色と状態の、ライトとダークのヘッダーの組。書き出して見比べるときにも使う。
    @MainActor
    static func accentPair(color: UIColor, followState: FollowState) -> UIView {
        // ライトとダークで同じアイコンを使い、画像を作るのを1回にする。
        let account = accentAccount(avatar: Fixtures.imageURL(width: 120, height: 120, color: color))
        let stack = UIStackView(arrangedSubviews: [UIUserInterfaceStyle.light, .dark].map { style in
            accentHeader(account, followState: followState, style: style)
        })
        stack.axis = .vertical
        return stack
    }

    /// 色とフォローの状態を選ぶ部品と、選んだ組み合わせのヘッダーの組。選び直すと、ヘッダーを作り直す。
    private final class AccentPicker: UIStackView {
        private let colorControl = UISegmentedControl()
        private let stateControl = UISegmentedControl(items: ProfileHeaderCatalog.accentFollowStates.map(\.name))
        private var pair: UIView?

        init() {
            super.init(frame: .zero)
            axis = .vertical
            spacing = 12
            // 名前を並べると幅に収まらないので、アイコンの色の丸を並べる。
            for (index, entry) in ProfileHeaderCatalog.accentColors.enumerated() {
                let dot = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
                    entry.color.setFill()
                    UIColor.separator.setStroke()
                    let path = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 16, height: 16))
                    path.fill()
                    path.stroke()
                }.withRenderingMode(.alwaysOriginal)
                dot.accessibilityLabel = entry.name
                colorControl.insertSegment(with: dot, at: index, animated: false)
            }
            colorControl.selectedSegmentIndex = 0
            stateControl.selectedSegmentIndex = 0
            colorControl.addAction(UIAction { [weak self] _ in self?.select() }, for: .valueChanged)
            stateControl.addAction(UIAction { [weak self] _ in self?.select() }, for: .valueChanged)
            addArrangedSubview(colorControl)
            addArrangedSubview(stateControl)
            select()
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func select() {
            pair?.removeFromSuperview()
            let entry = ProfileHeaderCatalog.accentColors[colorControl.selectedSegmentIndex]
            let state = ProfileHeaderCatalog.accentFollowStates[stateControl.selectedSegmentIndex]
            let view = ProfileHeaderCatalog.accentPair(color: entry.color, followState: state.state)
            addArrangedSubview(view)
            pair = view
        }
    }

    /// ライトかダークに固定した下地に、カードの色を付けたヘッダーを置く。カタログの画面ではなく、下地にティントカラーを当てる。
    @MainActor
    private static func accentHeader(_ account: Account, followState: FollowState, style: UIUserInterfaceStyle) -> UIView {
        let backdrop = UIView()
        backdrop.overrideUserInterfaceStyle = style
        backdrop.backgroundColor = .systemBackground
        // 自分にしか見えないメモの欄が、色を付けたカードと見分けられるかも見る。自分のプロフィールには出ない。
        let privateNote = followState == .myself ? "" : "自分にしか見えないメモ"
        let view = header(account, followState, pinned: Array(pinnedStatuses.prefix(2)), privateNote: privateNote) { header in
            header.accentOptions = ProfileCardPalette.Options(tuning: AppDependencies.tuning)
            header.onChangeScreenTint = { [weak backdrop] tint in backdrop?.tintColor = tint }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        return backdrop
    }

    @MainActor
    private static func header(
        _ account: Account,
        _ followState: FollowState,
        followedBy: Bool = false,
        isChangingFollow: Bool = false,
        isReloadingRelationship: Bool = false,
        showsRelationshipActivity: Bool = false,
        tab: ProfileTab = .posts,
        postsFilter: ProfilePostsFilter = .standard,
        avatarShape: AvatarShape = .circle,
        pinned: [Status] = [],
        privateNote: String = "",
        configure: (ProfileHeaderView) -> Void = { _ in }
    ) -> UIView {
        let header = ProfileHeaderView(
            emojiImages: AppDependencies.emojiImages,
            mediaImages: AppDependencies.mediaImages,
            avatarImages: AppDependencies.avatarImages
        )
        configure(header)
        var content = ProfileHeaderView.Content(
            account: account,
            followState: followState,
            followedBy: followedBy,
            isChangingFollow: isChangingFollow,
            isReloadingRelationship: isReloadingRelationship,
            showsRelationshipActivity: showsRelationshipActivity,
            tab: tab,
            postsFilter: postsFilter,
            avatarShape: avatarShape,
            animatesAvatar: false,
            animatesCustomEmojis: false,
            glyphLanguage: AppDependencies.settings.glyphLanguageIdentifier(),
            isRemote: account.acct.contains("@"),
            privateNote: privateNote,
            avatarDescription: account.avatarDescription,
            headerDescription: account.headerDescription
        )
        header.apply(content)
        // カタログは読み込み終えた状態を見せるので、一覧と一緒に出す部分も出しておく。
        header.setSectionsRevealed(true)
        // 実物と同じく、プロフィールの場所のサーバーのフィルターを当てる。
        let filtering = StatusFiltering(context: .account, myAccountID: nil)
        func items(_ statuses: [Status]) -> [ProfileShelfItem] {
            statuses.map { ProfileShelfItem(status: $0, verdict: filtering.verdict(for: $0)) }
        }
        header.setPinned(items(pinned), glyphLanguage: content.glyphLanguage)
        header.onToggleFollow = { [weak header] _ in
            content = content.replacing(followState: nextFollowState(after: content.followState, locked: account.locked))
            header?.apply(content)
        }
        // 再試行を押したら読み込み直す途中にし、少し待って読めたことにする。
        header.onRetryRelationship = { [weak header] in
            content = content.replacing(isReloadingRelationship: true)
            header?.apply(content)
            Task { @MainActor [weak header] in
                try? await Task.sleep(for: .seconds(1))
                content = content.replacing(followState: .notFollowing(locked: account.locked), isReloadingRelationship: false)
                header?.apply(content)
            }
        }
        header.onSelectTab = { [weak header] tab in
            content = content.replacing(tab: tab)
            header?.apply(content)
        }
        header.onChangePostsFilter = { [weak header] filter in
            content = content.replacing(postsFilter: filter)
            header?.apply(content)
        }
        return header
    }

    /// フォローのボタンを押したときに進める先。承認制なら承認待ちを挟み、外したら承認制のまま戻す。
    private static func nextFollowState(after state: FollowState, locked: Bool) -> FollowState {
        switch state {
        case .notFollowing(locked: true): .requested
        case .notFollowing(locked: false): .following
        case .requested, .following: .notFollowing(locked: locked)
        case .myself, .unknown, .loadFailed, .blocked: state
        }
    }
}

private extension ProfileHeaderView.Content {
    func replacing(followState: FollowState? = nil, isReloadingRelationship: Bool? = nil, tab: ProfileTab? = nil, postsFilter: ProfilePostsFilter? = nil) -> Self {
        Self(
            account: account,
            followState: followState ?? self.followState,
            followedBy: followedBy,
            isChangingFollow: isChangingFollow,
            isReloadingRelationship: isReloadingRelationship ?? self.isReloadingRelationship,
            showsRelationshipActivity: showsRelationshipActivity,
            tab: tab ?? self.tab,
            postsFilter: postsFilter ?? self.postsFilter,
            avatarShape: avatarShape,
            animatesAvatar: animatesAvatar,
            animatesCustomEmojis: animatesCustomEmojis,
            glyphLanguage: glyphLanguage,
            isRemote: isRemote,
            privateNote: privateNote,
            avatarDescription: avatarDescription,
            headerDescription: headerDescription
        )
    }
}
#endif
