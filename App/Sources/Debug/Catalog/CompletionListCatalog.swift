#if DEBUG
import SciaCore
import UIKit

/// 投稿欄の補完の候補の一覧（`ComposeCompletionList`）の状態。ガラスの効果を見られるよう、画像の上に置く。
/// 押しても何も起きない。一覧が欄の上や打っている行の下に重なる見え方は、実物で確かめる。
/// ふだんの出方に合わせて、いちばん優先する候補を一番下に置く（欄の上に出すとき）。上に置く出方は1つだけ並べる。
enum CompletionListCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        let emojiURL = CatalogFixtures.imageURL(width: 64, height: 64, color: .systemPink) ?? URL(filePath: "/")
        let accounts: [CompletionCandidate] = [
            .account(CatalogFixtures.account(displayName: "カタログ", acct: "catalog")),
            .account(CatalogFixtures.account(
                displayName: "とても長い表示名のアカウントで、一覧の幅に収まらないときに末尾が切れることを確かめる",
                acct: "a_very_long_username_for_checking_truncation@an.extremely.long.domain.example"
            )),
            .account(CatalogFixtures.account(displayName: "", acct: "no_display_name@example.com", avatar: nil)),
        ]
        let localMentions: [CompletionCandidate] = [
            .localAccount(LocalMention(account: CatalogFixtures.account(displayName: "返信先の投稿者", acct: "author")), .reply),
            .localAccount(LocalMention(mention: Mention(id: "catalog-mentioned", username: "mentioned", url: nil, acct: "mentioned@example.com")), .reply),
            .localAccount(LocalMention(account: CatalogFixtures.account(
                displayName: "前にメンションした長い表示名のアカウント",
                acct: "a_very_long_username_for_checking_truncation@an.extremely.long.domain.example"
            )), .recent),
        ]
        let hashtags: [CompletionCandidate] = [
            .ownHashtag(OwnHashtag(name: "猫写真", source: .featured(statusesCount: 12_345))),
            .ownHashtag(OwnHashtag(name: "猫鍋", source: .recent)),
            .hashtag(Hashtag(name: "猫", history: [Hashtag.History(uses: 17, accounts: 6), Hashtag.History(uses: 56, accounts: 22)])),
            .hashtag(Hashtag(name: "猫のいる暮らしと日々の写真と長いタグの名前が一覧の幅に収まらないとき")),
        ]
        let emojis: [CompletionCandidate] = [
            .emoji(ServerEmoji(shortcode: "blobcat", url: emojiURL, staticUrl: emojiURL)),
            .emoji(ServerEmoji(shortcode: "a_very_long_shortcode_for_a_custom_emoji_that_does_not_fit_in_the_list", url: emojiURL, staticUrl: emojiURL)),
        ]
        return [
            CatalogState(title: "メンションの候補（長い名前、表示名なし、アイコンなし）") { list(.candidates(accounts), kind: .mention) },
            CatalogState(title: "手元のメンションの候補（返信先、アイコンのないメンションされた人、前にメンションした長いハンドル）") { list(.candidates(localMentions), kind: .mention) },
            CatalogState(title: "ハードウェアキーボードで2つ目を選んでいる") { list(.candidates(accounts), kind: .mention, selected: 1) },
            CatalogState(title: "広げて打っている行の下に出すとき（一番上が最優先）") { list(.candidates(accounts), kind: .mention, growsUpward: false) },
            CatalogState(title: "ハッシュタグの候補（プロフィールのタグ、最近使ったタグ、最近の投稿の件数、長い名前）") { list(.candidates(hashtags), kind: .hashtag) },
            CatalogState(title: "カスタム絵文字の候補（長いショートコード）") { list(.candidates(emojis), kind: .emoji) },
            CatalogState(title: "候補を探している") { list(.loading, kind: .mention) },
            CatalogState(title: "一致するアカウントがない") { list(.empty, kind: .mention) },
            CatalogState(title: "一致するハッシュタグがない") { list(.empty, kind: .hashtag) },
            CatalogState(title: "一致する絵文字がない") { list(.empty, kind: .emoji) },
            CatalogState(title: "読み込めなかった（押すと読み込み直す）") {
                list(.failed(ComposeCompletion.failureMessage(for: MastodonAPIError(statusCode: 502, message: "Bad Gateway"))), kind: .mention)
            },
            CatalogState(title: "検索は読み込めなかったが、自分のタグは出せる") {
                list(.candidatesWithFailure(Array(hashtags.prefix(2)), ComposeCompletion.failureMessage(for: MastodonAPIError(statusCode: 502, message: "Bad Gateway"))), kind: .hashtag)
            },
            CatalogState(title: "読み込めなかった（制限中の長い理由）") {
                list(.failed(ComposeCompletion.failureMessage(for: AutomaticRequestsPaused(until: Date(timeIntervalSinceNow: 300)))), kind: .hashtag)
            },
        ]
    }

    @MainActor
    private static func list(_ content: ComposeCompletion.Content, kind: CompletionKind, selected: Int = 0, growsUpward: Bool = true) -> UIView {
        let list = ComposeCompletionList()
        list.growsUpward = growsUpward
        list.update(content, kind: kind, selectedIndex: selected)
        let height = list.contentHeight
        return CatalogBackdrop.image(list) { backdrop, list in
            [
                list.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
                list.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -24),
                // 投稿欄と同じく、左右に20ずつ空ける。
                list.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
                list.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
                list.heightAnchor.constraint(equalToConstant: height),
            ]
        }
    }
}
#endif
