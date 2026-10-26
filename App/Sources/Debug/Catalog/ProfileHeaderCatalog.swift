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
            status("media", "<p>添付ファイルのある投稿は、最初の1枚を右に小さく出す。</p>", media: [Fixtures.attachment("pinned-media", width: 1_200, height: 800, color: .systemOrange)], daysAgo: 30),
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
            CatalogState(title: "投稿の絞り込みを変えた（返信を含む）") {
                header(fullAccount, .following, postsFilter: ProfilePostsFilter(showsReplies: true, showsBoosts: true))
            },
        ]
    }

    @MainActor
    private static func header(
        _ account: Account,
        _ followState: FollowState,
        followedBy: Bool = false,
        isChangingFollow: Bool = false,
        isReloadingRelationship: Bool = false,
        tab: ProfileTab = .posts,
        postsFilter: ProfilePostsFilter = .standard,
        avatarShape: AvatarShape = .circle,
        pinned: [Status] = []
    ) -> UIView {
        let header = ProfileHeaderView(
            emojiImages: AppDependencies.emojiImages,
            mediaImages: AppDependencies.mediaImages,
            avatarImages: AppDependencies.avatarImages
        )
        var content = ProfileHeaderView.Content(
            account: account,
            followState: followState,
            followedBy: followedBy,
            isChangingFollow: isChangingFollow,
            isReloadingRelationship: isReloadingRelationship,
            tab: tab,
            postsFilter: postsFilter,
            avatarShape: avatarShape,
            animatesAvatar: false,
            animatesCustomEmojis: false,
            glyphLanguage: AppDependencies.settings.glyphLanguageIdentifier(),
            isRemote: account.acct.contains("@")
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
            tab: tab ?? self.tab,
            postsFilter: postsFilter ?? self.postsFilter,
            avatarShape: avatarShape,
            animatesAvatar: animatesAvatar,
            animatesCustomEmojis: animatesCustomEmojis,
            glyphLanguage: glyphLanguage,
            isRemote: isRemote
        )
    }
}
#endif
