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

    /// 届いた通知を、ステータスバーの場所に流す。
    public var showsStatusBarTicker: Bool {
        didSet { defaults.set(showsStatusBarTicker, forKey: Keys.showsStatusBarTicker) }
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

    /// 本文や名前のUnicodeの絵文字を描く絵。
    public var emojiStyle: EmojiStyle {
        didSet { defaults.set(emojiStyle.rawValue, forKey: Keys.emojiStyle) }
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

    /// GIFやAPNGのアニメーションするカスタム絵文字を動かす。オフなら最初のコマで止めた版を描く。
    public var animatesCustomEmojis: Bool {
        didSet { defaults.set(animatesCustomEmojis, forKey: Keys.animatesCustomEmojis) }
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

    /// メニューの「ブースト」でブーストするときの公開範囲。
    public var reblogVisibility: ReblogVisibility {
        didSet { defaults.set(reblogVisibility.rawValue, forKey: Keys.reblogVisibility) }
    }

    /// アカウントごとのタブの並び。鍵はアカウントのハンドル。保存していないアカウントは既定の並びを使う。
    public private(set) var tabLayouts: [String: MenuLayout<TabItem>] {
        didSet { defaults.set(tabLayouts.mapValues(\.tokens), forKey: Keys.tabLayouts) }
    }

    /// - Parameter account: アカウントのハンドル（`Credential.handle`）。
    public func tabLayout(for account: String) -> MenuLayout<TabItem> {
        tabLayouts[account] ?? TabItem.defaultLayout
    }

    public func setTabLayout(_ layout: MenuLayout<TabItem>, for account: String) {
        tabLayouts[account] = layout
    }

    /// アカウントごとの、切り替えタブで最後に開いた項目。鍵はアカウントのハンドル。
    /// 開くたびに書くので、ほかの設定と違って変更を購読させない。
    @ObservationIgnored private var switchTabItems: [String: TabItem] {
        didSet { defaults.set(switchTabItems.mapValues(\.rawValue), forKey: Keys.switchTabItems) }
    }

    public func switchTabItem(for account: String) -> TabItem? {
        switchTabItems[account]
    }

    public func setSwitchTabItem(_ item: TabItem, for account: String) {
        guard switchTabItems[account] != item else { return }
        switchTabItems[account] = item
    }

    /// 投稿を長押しして出すメニューの並び。通知のメニューもこれで組む。
    public var statusMenuLayout: MenuLayout<StatusMenuItem> {
        didSet { defaults.set(statusMenuLayout.tokens, forKey: Keys.statusMenuLayout) }
    }

    /// 投稿のメニューの中に、ユーザーごとのサブメニューとして出すメニューの並び。
    public var userMenuLayout: MenuLayout<UserMenuItem> {
        didSet { defaults.set(userMenuLayout.tokens, forKey: Keys.userMenuLayout) }
    }

    /// 本文のURLのリンクを長押しして出すメニューの並び。メンションはユーザーのメニューで出す。
    public var linkMenuLayout: MenuLayout<LinkMenuItem> {
        didSet { defaults.set(linkMenuLayout.tokens, forKey: Keys.linkMenuLayout) }
    }

    /// 本文のハッシュタグを長押しして出すメニューの並び。
    public var hashtagMenuLayout: MenuLayout<HashtagMenuItem> {
        didSet { defaults.set(hashtagMenuLayout.tokens, forKey: Keys.hashtagMenuLayout) }
    }

    /// メディアを長押ししたときと、ビューアのメニューの並び。
    public var mediaMenuLayout: MenuLayout<MediaMenuItem> {
        didSet { defaults.set(mediaMenuLayout.tokens, forKey: Keys.mediaMenuLayout) }
    }

    /// 投稿欄の部品を足す項目の並び。どれをボタンの行に常に出し、どれを＋のメニューに入れるか。
    public var composeToolLayout: MenuLayout<ComposeToolItem> {
        didSet { defaults.set(composeToolLayout.tokens, forKey: Keys.composeToolLayout) }
    }

    /// 書いていないときに、空の投稿欄を隠す。書くときは、一覧の右上のボタンで出す。
    /// 下書きや返信先があるときは、残っていると分かるよう隠さない。
    public var hidesEmptyComposeBar: Bool {
        didSet { defaults.set(hidesEmptyComposeBar, forKey: Keys.hidesEmptyComposeBar) }
    }

    /// 送る前に画像を縮める大きさ。選んだ大きさに収まる画像は元のまま送る。
    public var imageUploadSize: ImageUploadSize {
        didSet { defaults.set(imageUploadSize.rawValue, forKey: Keys.imageUploadSize) }
    }

    /// 送る前に動画を縮める大きさ。選んだ大きさに収まる動画は元のまま送る。
    public var videoUploadSize: VideoUploadSize {
        didSet { defaults.set(videoUploadSize.rawValue, forKey: Keys.videoUploadSize) }
    }

    /// ビューアの外（一覧、プロフィール、リンクカード、投稿欄のサムネイルなど）で、HDRのメディアを描く明るさ。
    public var mediaDynamicRange: MediaDynamicRange {
        didSet { defaults.set(mediaDynamicRange.rawValue, forKey: Keys.mediaDynamicRange) }
    }

    /// お気に入りとブーストの光を、HDRで描ける画面では白より明るく光らせる。オフならSDRで描く。
    /// メディアの明るさの設定（`mediaDynamicRange`）はメディアに対するものなので、光はそれに従わせず、ここで別に選ぶ。
    public var drawsReactionGlowInHDR: Bool {
        didSet { defaults.set(drawsReactionGlowInHDR, forKey: Keys.drawsReactionGlowInHDR) }
    }

    /// ビューアで、HDRのメディアを描く明るさ。
    public var viewerMediaDynamicRange: MediaDynamicRange {
        didSet { defaults.set(viewerMediaDynamicRange.rawValue, forKey: Keys.viewerMediaDynamicRange) }
    }

    private enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "settings.usesOriginalThumbnailsOnExpensiveNetwork"
        static let ignoresUselessAltText = "settings.ignoresUselessAltText"
        static let showsStatusBarTicker = "settings.showsStatusBarTicker"
        static let statusNameStyle = "settings.statusNameStyle"
        static let statusTimeStyle = "settings.statusTimeStyle"
        static let glyphLanguage = "settings.glyphLanguage"
        static let emojiStyle = "settings.emojiStyle"
        static let avatarShape = "settings.avatarShape"
        static let animatesAvatars = "settings.animatesAvatars"
        static let animatesCustomEmojis = "settings.animatesCustomEmojis"
        static let linkCardThumbnailSide = "settings.linkCardThumbnailSide"
        static let insertionMotion = "settings.insertionMotion"
        static let profileShowsReplies = "settings.profileShowsReplies"
        static let profileShowsBoosts = "settings.profileShowsBoosts"
        static let linkBrowser = "settings.linkBrowser"
        static let reblogVisibility = "settings.reblogVisibility"
        static let statusMenuLayout = "settings.statusMenuLayout"
        static let userMenuLayout = "settings.userMenuLayout"
        static let linkMenuLayout = "settings.linkMenuLayout"
        static let hashtagMenuLayout = "settings.hashtagMenuLayout"
        static let mediaMenuLayout = "settings.mediaMenuLayout"
        static let composeToolLayout = "settings.composeToolLayout"
        static let tabLayouts = "settings.tabLayouts"
        static let switchTabItems = "settings.switchTabItems"
        static let hidesEmptyComposeBar = "settings.hidesEmptyComposeBar"
        static let imageUploadSize = "settings.imageUploadSize"
        static let videoUploadSize = "settings.videoUploadSize"
        static let mediaDynamicRange = "settings.mediaDynamicRange"
        static let viewerMediaDynamicRange = "settings.viewerMediaDynamicRange"
        static let drawsReactionGlowInHDR = "settings.drawsReactionGlowInHDR"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        usesOriginalThumbnailsOnExpensiveNetwork = defaults.object(forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) as? Bool ?? true
        ignoresUselessAltText = defaults.object(forKey: Keys.ignoresUselessAltText) as? Bool ?? true
        showsStatusBarTicker = defaults.object(forKey: Keys.showsStatusBarTicker) as? Bool ?? true
        statusNameStyle = defaults.string(forKey: Keys.statusNameStyle).flatMap(StatusNameStyle.init(rawValue:)) ?? .nameAndAcct
        statusTimeStyle = defaults.string(forKey: Keys.statusTimeStyle).flatMap(StatusTimeStyle.init(rawValue:)) ?? .relative
        glyphLanguage = defaults.string(forKey: Keys.glyphLanguage).flatMap(GlyphLanguage.init(rawValue:)) ?? .automatic
        emojiStyle = defaults.string(forKey: Keys.emojiStyle).flatMap(EmojiStyle.init(rawValue:)) ?? .system
        avatarShape = defaults.string(forKey: Keys.avatarShape).flatMap(AvatarShape.init(rawValue:)) ?? .roundedSquare
        animatesAvatars = defaults.object(forKey: Keys.animatesAvatars) as? Bool ?? false
        animatesCustomEmojis = defaults.object(forKey: Keys.animatesCustomEmojis) as? Bool ?? false
        linkCardThumbnailSide = defaults.string(forKey: Keys.linkCardThumbnailSide).flatMap(LinkCardThumbnailSide.init(rawValue:)) ?? .left
        insertionMotion = defaults.string(forKey: Keys.insertionMotion).flatMap(InsertionMotion.init(rawValue:)) ?? .followsSystem
        linkBrowser = defaults.string(forKey: Keys.linkBrowser).flatMap(LinkBrowser.init(rawValue:)) ?? .external
        reblogVisibility = defaults.string(forKey: Keys.reblogVisibility).flatMap(ReblogVisibility.init(rawValue:)) ?? .accountDefault
        statusMenuLayout = defaults.stringArray(forKey: Keys.statusMenuLayout).map(MenuLayout.init(tokens:)) ?? StatusMenuItem.defaultLayout
        userMenuLayout = defaults.stringArray(forKey: Keys.userMenuLayout).map(MenuLayout.init(tokens:)) ?? UserMenuItem.defaultLayout
        linkMenuLayout = defaults.stringArray(forKey: Keys.linkMenuLayout).map(MenuLayout.init(tokens:)) ?? LinkMenuItem.defaultLayout
        hashtagMenuLayout = defaults.stringArray(forKey: Keys.hashtagMenuLayout).map(MenuLayout.init(tokens:)) ?? HashtagMenuItem.defaultLayout
        mediaMenuLayout = defaults.stringArray(forKey: Keys.mediaMenuLayout).map(MenuLayout.init(tokens:)) ?? MediaMenuItem.defaultLayout
        composeToolLayout = defaults.stringArray(forKey: Keys.composeToolLayout).map(MenuLayout.init(tokens:)) ?? ComposeToolItem.defaultLayout
        tabLayouts = (defaults.dictionary(forKey: Keys.tabLayouts) as? [String: [String]] ?? [:]).mapValues(MenuLayout.init(tokens:))
        switchTabItems = (defaults.dictionary(forKey: Keys.switchTabItems) as? [String: String] ?? [:]).compactMapValues(TabItem.init(rawValue:))
        hidesEmptyComposeBar = defaults.object(forKey: Keys.hidesEmptyComposeBar) as? Bool ?? false
        // iPhoneの標準の写真（4032×3024）と動画（1080p）はそのまま送られ、それより大きな写真と4Kの動画だけが縮む。
        imageUploadSize = defaults.string(forKey: Keys.imageUploadSize).flatMap(ImageUploadSize.init(rawValue:)) ?? .long4096
        videoUploadSize = defaults.string(forKey: Keys.videoUploadSize).flatMap(VideoUploadSize.init(rawValue:)) ?? .p1080
        mediaDynamicRange = defaults.string(forKey: Keys.mediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .standard
        viewerMediaDynamicRange = defaults.string(forKey: Keys.viewerMediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .constrainedHigh
        drawsReactionGlowInHDR = defaults.object(forKey: Keys.drawsReactionGlowInHDR) as? Bool ?? true
        profilePostsFilter = ProfilePostsFilter(
            showsReplies: defaults.object(forKey: Keys.profileShowsReplies) as? Bool ?? ProfilePostsFilter.standard.showsReplies,
            showsBoosts: defaults.object(forKey: Keys.profileShowsBoosts) as? Bool ?? ProfilePostsFilter.standard.showsBoosts
        )
    }
}
