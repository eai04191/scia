public import Foundation
public import Observation

/// 使う人が設定画面で選ぶ値。変更はObservationで購読できる。
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// モバイル通信とインターネット共有でも、一覧のサムネイルに元の画像を読む。
    /// オフなら、サーバーが縮めたプレビュー画像を読む。
    public var usesOriginalThumbnailsOnExpensiveNetwork: Bool {
        didSet { defaults.set(usesOriginalThumbnailsOnExpensiveNetwork, forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) }
    }

    /// 「undefined」や「Screenshot」のような、説明にならない代替テキストを付いていないものとして扱う。
    public var ignoresUselessAltText: Bool {
        didSet { defaults.set(ignoresUselessAltText, forKey: Keys.ignoresUselessAltText) }
    }

    /// 投稿の名前の行に、表示名とacctをどう並べるか。
    public var statusNameStyle: StatusNameStyle {
        didSet { defaults.set(statusNameStyle.rawValue, forKey: Keys.statusNameStyle) }
    }

    public var statusTimeStyle: StatusTimeStyle {
        didSet { defaults.set(statusTimeStyle.rawValue, forKey: Keys.statusTimeStyle) }
    }

    /// 漢字とかなを描く字形。投稿に日本語・中国語・韓国語の言語が付いていれば、そちらを優先する。
    public var glyphLanguage: GlyphLanguage {
        didSet { defaults.set(glyphLanguage.rawValue, forKey: Keys.glyphLanguage) }
    }

    public var avatarShape: AvatarShape {
        didSet { defaults.set(avatarShape.rawValue, forKey: Keys.avatarShape) }
    }

    /// リンクカードのサムネイルを置く端。
    public var linkCardThumbnailSide: LinkCardThumbnailSide {
        didSet { defaults.set(linkCardThumbnailSide.rawValue, forKey: Keys.linkCardThumbnailSide) }
    }

    /// 一覧で、GIFなどのアニメーションするアイコンを動かす。オフなら最初のコマで止めた版を読む。
    public var animatesAvatars: Bool {
        didSet { defaults.set(animatesAvatars, forKey: Keys.animatesAvatars) }
    }

    /// 最上部で新着に追従しているとき、新着を足してから最上部へ動かして見せるか。最上部より下で読んでいるときは、読んでいる位置を保つため動かさない。
    public var insertionMotion: InsertionMotion {
        didSet { defaults.set(insertionMotion.rawValue, forKey: Keys.insertionMotion) }
    }

    /// プロフィール画面の「投稿」に、返信とブーストを混ぜるか。どのアカウントのプロフィールにも効かせる。
    public var profilePostsFilter: ProfilePostsFilter {
        didSet {
            defaults.set(profilePostsFilter.showsReplies, forKey: Keys.profileShowsReplies)
            defaults.set(profilePostsFilter.showsBoosts, forKey: Keys.profileShowsBoosts)
        }
    }

    /// 本文のURLのリンクを、既定のブラウザとアプリ内のSafariのどちらで開くか。
    public var linkBrowser: LinkBrowser {
        didSet { defaults.set(linkBrowser.rawValue, forKey: Keys.linkBrowser) }
    }

    /// 投稿を長押しして出すメニューの並び。通知のメニューもこれで組む。
    public var statusMenuLayout: MenuLayout<StatusMenuItem> {
        didSet { defaults.set(statusMenuLayout.tokens, forKey: Keys.statusMenuLayout) }
    }

    /// 投稿のメニューの中に、ユーザーごとのサブメニューとして出すメニューの並び。
    public var userMenuLayout: MenuLayout<UserMenuItem> {
        didSet { defaults.set(userMenuLayout.tokens, forKey: Keys.userMenuLayout) }
    }

    /// 投稿欄の部品を足す項目の並び。どれをボタンの行に常に出し、どれを＋のメニューに入れるか。
    public var composeToolLayout: MenuLayout<ComposeToolItem> {
        didSet { defaults.set(composeToolLayout.tokens, forKey: Keys.composeToolLayout) }
    }

    private enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "settings.usesOriginalThumbnailsOnExpensiveNetwork"
        static let ignoresUselessAltText = "settings.ignoresUselessAltText"
        static let statusNameStyle = "settings.statusNameStyle"
        static let statusTimeStyle = "settings.statusTimeStyle"
        static let glyphLanguage = "settings.glyphLanguage"
        static let avatarShape = "settings.avatarShape"
        static let animatesAvatars = "settings.animatesAvatars"
        static let linkCardThumbnailSide = "settings.linkCardThumbnailSide"
        static let insertionMotion = "settings.insertionMotion"
        static let profileShowsReplies = "settings.profileShowsReplies"
        static let profileShowsBoosts = "settings.profileShowsBoosts"
        static let linkBrowser = "settings.linkBrowser"
        static let statusMenuLayout = "settings.statusMenuLayout"
        static let userMenuLayout = "settings.userMenuLayout"
        static let composeToolLayout = "settings.composeToolLayout"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        usesOriginalThumbnailsOnExpensiveNetwork = defaults.object(forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) as? Bool ?? true
        ignoresUselessAltText = defaults.object(forKey: Keys.ignoresUselessAltText) as? Bool ?? true
        statusNameStyle = defaults.string(forKey: Keys.statusNameStyle).flatMap(StatusNameStyle.init(rawValue:)) ?? .nameAndAcct
        statusTimeStyle = defaults.string(forKey: Keys.statusTimeStyle).flatMap(StatusTimeStyle.init(rawValue:)) ?? .relative
        glyphLanguage = defaults.string(forKey: Keys.glyphLanguage).flatMap(GlyphLanguage.init(rawValue:)) ?? .automatic
        avatarShape = defaults.string(forKey: Keys.avatarShape).flatMap(AvatarShape.init(rawValue:)) ?? .roundedSquare
        animatesAvatars = defaults.object(forKey: Keys.animatesAvatars) as? Bool ?? false
        linkCardThumbnailSide = defaults.string(forKey: Keys.linkCardThumbnailSide).flatMap(LinkCardThumbnailSide.init(rawValue:)) ?? .left
        insertionMotion = defaults.string(forKey: Keys.insertionMotion).flatMap(InsertionMotion.init(rawValue:)) ?? .followsSystem
        linkBrowser = defaults.string(forKey: Keys.linkBrowser).flatMap(LinkBrowser.init(rawValue:)) ?? .external
        statusMenuLayout = defaults.stringArray(forKey: Keys.statusMenuLayout).map(MenuLayout.init(tokens:)) ?? StatusMenuItem.defaultLayout
        userMenuLayout = defaults.stringArray(forKey: Keys.userMenuLayout).map(MenuLayout.init(tokens:)) ?? UserMenuItem.defaultLayout
        composeToolLayout = defaults.stringArray(forKey: Keys.composeToolLayout).map(MenuLayout.init(tokens:)) ?? ComposeToolItem.defaultLayout
        profilePostsFilter = ProfilePostsFilter(
            showsReplies: defaults.object(forKey: Keys.profileShowsReplies) as? Bool ?? ProfilePostsFilter.standard.showsReplies,
            showsBoosts: defaults.object(forKey: Keys.profileShowsBoosts) as? Bool ?? ProfilePostsFilter.standard.showsBoosts
        )
    }
}
