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

    /// 名前の上の行で、ブーストした人の表示名とacctをどう並べるか。
    public var contextNameStyle: StatusNameStyle {
        didSet { defaults.set(contextNameStyle.rawValue, forKey: Keys.contextNameStyle) }
    }

    /// 時刻の前に、公開でない投稿の公開範囲の記号を出す。
    public var showsVisibilitySymbol: Bool {
        didSet { defaults.set(showsVisibilitySymbol, forKey: Keys.showsVisibilitySymbol) }
    }

    /// 編集された投稿の時刻の前に「*」を出す。
    public var showsEditedMark: Bool {
        didSet { defaults.set(showsEditedMark, forKey: Keys.showsEditedMark) }
    }

    /// 名前の上の行に、ブーストした人のアイコンを出す。
    public var showsBoosterAvatar: Bool {
        didSet { defaults.set(showsBoosterAvatar, forKey: Keys.showsBoosterAvatar) }
    }

    /// 返信の名前の上に、返信先を示すラベルを出す。
    public var showsReplyLabel: Bool {
        didSet { defaults.set(showsReplyLabel, forKey: Keys.showsReplyLabel) }
    }

    /// 返信と返信先の行のアイコンを、線でつなぐ。
    public var showsReplyLines: Bool {
        didSet { defaults.set(showsReplyLines, forKey: Keys.showsReplyLines) }
    }

    /// 名前の行の右端に、時刻を出す。
    public var showsTime: Bool {
        didSet { defaults.set(showsTime, forKey: Keys.showsTime) }
    }

    /// リンクカードに画像を出す。
    public var showsLinkCardImage: Bool {
        didSet { defaults.set(showsLinkCardImage, forKey: Keys.showsLinkCardImage) }
    }

    /// 名前の上の行の先頭に、ブーストや返信を示す記号を出す。
    public var showsContextSymbol: Bool {
        didSet { defaults.set(showsContextSymbol, forKey: Keys.showsContextSymbol) }
    }

    /// 名前の行の先頭の部分を太字にする。
    public var boldsName: Bool {
        didSet { defaults.set(boldsName, forKey: Keys.boldsName) }
    }

    /// アイコンの縁に細い線を引く。
    public var showsAvatarBorder: Bool {
        didSet { defaults.set(showsAvatarBorder, forKey: Keys.showsAvatarBorder) }
    }

    /// サムネイルに、代替テキストやGIFなどを示すバッジを出す。
    public var showsMediaBadges: Bool {
        didSet { defaults.set(showsMediaBadges, forKey: Keys.showsMediaBadges) }
    }

    /// 投稿にリンクカードを出す。
    public var showsLinkCard: Bool {
        didSet { defaults.set(showsLinkCard, forKey: Keys.showsLinkCard) }
    }

    /// リンクカードのタイトルを太字にする。
    public var boldsLinkCardTitle: Bool {
        didSet { defaults.set(boldsLinkCardTitle, forKey: Keys.boldsLinkCardTitle) }
    }

    /// 一覧の投稿と投稿のあいだに区切り線を引く。
    public var showsSeparators: Bool {
        didSet { defaults.set(showsSeparators, forKey: Keys.showsSeparators) }
    }

    /// リンクカードの一番上に、サイト名を出す。
    public var showsLinkCardSite: Bool {
        didSet { defaults.set(showsLinkCardSite, forKey: Keys.showsLinkCardSite) }
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
    /// 一覧の投稿の添付ファイルを、本文の下に並べるか、本文の右に小さく出すか。
    public var mediaArrangement: MediaArrangement {
        didSet { defaults.set(mediaArrangement.rawValue, forKey: Keys.mediaArrangement) }
    }

    /// 本文の右に重ねた写真を傾ける。オフなら、どの写真もまっすぐに置き、投稿ごとに角度をばらつかせない。
    public var tiltsStackedPhotos: Bool {
        didSet { defaults.set(tiltsStackedPhotos, forKey: Keys.tiltsStackedPhotos) }
    }

    public var animatesAvatars: Bool {
        didSet { defaults.set(animatesAvatars, forKey: Keys.animatesAvatars) }
    }

    /// GIFやAPNGのアニメーションするカスタム絵文字を動かす。オフなら最初のコマで止めた版を描く。
    public var animatesCustomEmojis: Bool {
        didSet { defaults.set(animatesCustomEmojis, forKey: Keys.animatesCustomEmojis) }
    }

    /// お気に入りとブーストの光に、何を示すかのアイコンを添えるか。
    public var reactionGlowIcons: ReactionGlowIcons {
        didSet { defaults.set(reactionGlowIcons.rawValue, forKey: Keys.reactionGlowIcons) }
    }

    /// お気に入りとブーストの片方だけをしたときに、その色で全幅を光らせる。オフなら、その半分だけを光らせる。
    public var reactionGlowFillsWidthWhenAlone: Bool {
        didSet { defaults.set(reactionGlowFillsWidthWhenAlone, forKey: Keys.reactionGlowFillsWidthWhenAlone) }
    }

    public var reactionGlowLightFavouriteColor: ReactionGlowLightFavouriteColor {
        didSet { defaults.set(reactionGlowLightFavouriteColor.rawValue, forKey: Keys.reactionGlowLightFavouriteColor) }
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

    /// 「投稿の見た目」と「通知の見た目」で変えた数値。キーは`AppearanceValue.id`。既定値のままの項目は持たない。
    public private(set) var appearanceValues: [String: Double]

    public func value(of item: AppearanceValue) -> Double {
        appearanceValues[item.id] ?? item.defaultValue
    }

    /// 範囲外の値は範囲内に丸めて保存する。数でない値（NaNや無限）は、行数などを整数に直すところで落ちるため、保存しない。
    public func setValue(_ value: Double, for item: AppearanceValue) {
        guard value.isFinite else { return }
        let clamped = min(max(Self.snapped(value, toMultipleOf: item.step), item.range.lowerBound), item.range.upperBound)
        appearanceValues[item.id] = clamped
        defaults.set(clamped, forKey: Keys.appearance(item.id))
    }

    /// 刻みの倍数との差が計算の誤差ほどしかない値を、その倍数にする。＋−（`Stepper`）は今の値に刻みを足すので、
    /// 0.1のように2進数で表せない刻みでは誤差が溜まり、既定値まで戻しても既定値と一致しなくなるため。打って入れた、倍数から離れた値は変えない。
    /// 小数の刻みは逆数（0.1なら10）で割って作る。刻みを掛けると、掛け算でも誤差が出るため。
    static func snapped(_ value: Double, toMultipleOf step: Double) -> Double {
        let steps = value / step
        let nearest = steps.rounded()
        guard abs(steps - nearest) < 1e-9 else { return value }
        return step < 1 ? nearest / (1 / step).rounded() : nearest * step
    }

    public func isModified(_ item: AppearanceValue) -> Bool {
        value(of: item) != item.defaultValue
    }

    /// 「投稿の見た目」の数値か選択肢のどれかが、既定値から変わっているか。
    public var isAppearanceModified: Bool {
        typealias D = AppearanceDefaults
        return AppearanceCatalog.values.contains(where: isModified) || statusNameStyle != D.statusNameStyle || statusTimeStyle != D.statusTimeStyle || contextNameStyle != D.contextNameStyle || glyphLanguage != D.glyphLanguage || emojiStyle != D.emojiStyle || avatarShape != D.avatarShape || linkCardThumbnailSide != D.linkCardThumbnailSide || mediaArrangement != D.mediaArrangement || tiltsStackedPhotos != D.tiltsStackedPhotos || showsVisibilitySymbol != D.showsVisibilitySymbol || showsEditedMark != D.showsEditedMark || showsLinkCardSite != D.showsLinkCardSite || showsContextSymbol != D.showsContextSymbol || boldsName != D.boldsName || showsAvatarBorder != D.showsAvatarBorder || showsMediaBadges != D.showsMediaBadges || showsLinkCard != D.showsLinkCard || boldsLinkCardTitle != D.boldsLinkCardTitle || showsSeparators != D.showsSeparators || showsBoosterAvatar != D.showsBoosterAvatar || showsReplyLabel != D.showsReplyLabel || showsReplyLines != D.showsReplyLines || showsTime != D.showsTime || showsLinkCardImage != D.showsLinkCardImage || animatesAvatars != D.animatesAvatars || animatesCustomEmojis != D.animatesCustomEmojis || drawsReactionGlowInHDR != D.drawsReactionGlowInHDR || reactionGlowIcons != D.reactionGlowIcons || reactionGlowFillsWidthWhenAlone != D.reactionGlowFillsWidthWhenAlone || reactionGlowLightFavouriteColor != D.reactionGlowLightFavouriteColor
    }

    /// 「投稿の見た目」の数値と選択肢を、すべて既定値へ戻す。
    public func resetAppearance() {
        typealias D = AppearanceDefaults
        reset(AppearanceCatalog.values)
        statusNameStyle = D.statusNameStyle
        statusTimeStyle = D.statusTimeStyle
        contextNameStyle = D.contextNameStyle
        glyphLanguage = D.glyphLanguage
        emojiStyle = D.emojiStyle
        avatarShape = D.avatarShape
        linkCardThumbnailSide = D.linkCardThumbnailSide
        mediaArrangement = D.mediaArrangement
        tiltsStackedPhotos = D.tiltsStackedPhotos
        showsVisibilitySymbol = D.showsVisibilitySymbol
        showsEditedMark = D.showsEditedMark
        showsLinkCardSite = D.showsLinkCardSite
        showsContextSymbol = D.showsContextSymbol
        boldsName = D.boldsName
        showsAvatarBorder = D.showsAvatarBorder
        showsMediaBadges = D.showsMediaBadges
        showsLinkCard = D.showsLinkCard
        boldsLinkCardTitle = D.boldsLinkCardTitle
        showsSeparators = D.showsSeparators
        showsBoosterAvatar = D.showsBoosterAvatar
        showsReplyLabel = D.showsReplyLabel
        showsReplyLines = D.showsReplyLines
        showsTime = D.showsTime
        showsLinkCardImage = D.showsLinkCardImage
        animatesAvatars = D.animatesAvatars
        animatesCustomEmojis = D.animatesCustomEmojis
        drawsReactionGlowInHDR = D.drawsReactionGlowInHDR
        reactionGlowIcons = D.reactionGlowIcons
        reactionGlowFillsWidthWhenAlone = D.reactionGlowFillsWidthWhenAlone
        reactionGlowLightFavouriteColor = D.reactionGlowLightFavouriteColor
    }

    /// 「通知の見た目」の数値のどれかが、既定値から変わっているか。
    public var isNotificationAppearanceModified: Bool {
        NotificationAppearanceCatalog.values.contains(where: isModified)
    }

    /// 「通知の見た目」の数値を、すべて既定値へ戻す。
    public func resetNotificationAppearance() {
        reset(NotificationAppearanceCatalog.values)
    }

    /// 項目を既定値へ戻す。
    public func reset(_ items: [AppearanceValue]) {
        for item in items {
            appearanceValues[item.id] = nil
            defaults.removeObject(forKey: Keys.appearance(item.id))
        }
    }

    /// アカウントごとのタブの並び。キーはアカウントのハンドル。保存していないアカウントは既定の並びを使う。
    /// ログアウトで消せるよう、アカウントごとのキー（`AccountScopedDefaults`）に1つずつ保存する。
    public private(set) var tabLayouts: [String: MenuLayout<TabItem>]

    /// - Parameter account: アカウントのハンドル（`Credential.handle`）。
    public func tabLayout(for account: String) -> MenuLayout<TabItem> {
        tabLayouts[account] ?? TabItem.defaultLayout
    }

    public func setTabLayout(_ layout: MenuLayout<TabItem>, for account: String) {
        tabLayouts[account] = layout
        defaults.set(layout.tokens, forKey: AccountScopedDefaults.key(Keys.tabLayout, account: account))
    }

    /// アカウントごとの、切り替えタブで最後に開いた項目。キーはアカウントのハンドル。
    /// 開くたびに書くので、ほかの設定と違って変更を購読させない。
    @ObservationIgnored private var switchTabItems: [String: TabItem]

    public func switchTabItem(for account: String) -> TabItem? {
        switchTabItems[account]
    }

    public func setSwitchTabItem(_ item: TabItem, for account: String) {
        guard switchTabItems[account] != item else { return }
        switchTabItems[account] = item
        defaults.set(item.rawValue, forKey: AccountScopedDefaults.key(Keys.switchTabItem, account: account))
    }

    /// ログアウトしたアカウントの並びと最後に開いた項目を忘れる。保存したキーは`AccountScopedDefaults.removeData`が消す。
    func forgetAccount(_ account: String) {
        tabLayouts[account] = nil
        switchTabItems[account] = nil
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

    /// ほかのサービスの投稿（Xの投稿の囲みなど）を長押しして出すメニューの並び。
    public var externalPostMenuLayout: MenuLayout<ExternalPostMenuItem> {
        didSet { defaults.set(externalPostMenuLayout.tokens, forKey: Keys.externalPostMenuLayout) }
    }

    /// プロフィールの表示名、自己紹介、補足情報の行を長押しして出すメニューの並び。
    public var profileTextMenuLayout: MenuLayout<ProfileTextMenuItem> {
        didSet { defaults.set(profileTextMenuLayout.tokens, forKey: Keys.profileTextMenuLayout) }
    }

    /// 本文のハッシュタグを長押しして出すメニューの並び。
    public var hashtagMenuLayout: MenuLayout<HashtagMenuItem> {
        didSet { defaults.set(hashtagMenuLayout.tokens, forKey: Keys.hashtagMenuLayout) }
    }

    /// メディアを長押ししたときと、ビューアのメニューの並び。
    public var mediaMenuLayout: MenuLayout<MediaMenuItem> {
        didSet { defaults.set(mediaMenuLayout.tokens, forKey: Keys.mediaMenuLayout) }
    }

    /// 投稿の行と引用の囲みをタップ、長押ししたときの操作。決まりはdocs/object-actions.mdにある。
    public var statusActions: ObjectActions<StatusMenuItem> {
        didSet { defaults.set(statusActions.tokens, forKey: Keys.statusActions) }
    }

    /// 通知の行をタップ、長押ししたときの操作。項目は投稿のメニューから選ぶ。
    public var notificationActions: ObjectActions<StatusMenuItem> {
        didSet { defaults.set(notificationActions.tokens, forKey: Keys.notificationActions) }
    }

    /// アイコン、「〜がブースト」の行、人の一覧の行、メンションをタップ、長押ししたときの操作。
    public var userActions: ObjectActions<UserMenuItem> {
        didSet { defaults.set(userActions.tokens, forKey: Keys.userActions) }
    }

    /// URLのリンク、リンクカードをタップ、長押ししたときの操作。
    public var linkActions: ObjectActions<LinkMenuItem> {
        didSet { defaults.set(linkActions.tokens, forKey: Keys.linkActions) }
    }

    /// ほかのサービスの投稿（Xの投稿の囲みなど）をタップ、長押ししたときの操作。
    public var externalPostActions: ObjectActions<ExternalPostMenuItem> {
        didSet { defaults.set(externalPostActions.tokens, forKey: Keys.externalPostActions) }
    }

    /// ハッシュタグをタップ、長押ししたときの操作。
    public var hashtagActions: ObjectActions<HashtagMenuItem> {
        didSet { defaults.set(hashtagActions.tokens, forKey: Keys.hashtagActions) }
    }

    /// サムネイル、リンクカードの画像、プロフィールの画像をタップ、長押ししたときの操作。ビューアの中は含めない。
    public var mediaActions: ObjectActions<MediaMenuItem> {
        didSet { defaults.set(mediaActions.tokens, forKey: Keys.mediaActions) }
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
        static let contextNameStyle = "settings.contextNameStyle"
        static let showsVisibilitySymbol = "settings.showsVisibilitySymbol"
        static let showsEditedMark = "settings.showsEditedMark"
        static let showsLinkCardSite = "settings.showsLinkCardSite"
        static let showsContextSymbol = "settings.showsContextSymbol"
        static let boldsName = "settings.boldsName"
        static let showsAvatarBorder = "settings.showsAvatarBorder"
        static let showsMediaBadges = "settings.showsMediaBadges"
        static let showsLinkCard = "settings.showsLinkCard"
        static let boldsLinkCardTitle = "settings.boldsLinkCardTitle"
        static let showsSeparators = "settings.showsSeparators"
        static let showsBoosterAvatar = "settings.showsBoosterAvatar"
        static let showsReplyLabel = "settings.showsReplyLabel"
        static let showsReplyLines = "settings.showsReplyLines"
        static let showsTime = "settings.showsTime"
        static let showsLinkCardImage = "settings.showsLinkCardImage"
        static let glyphLanguage = "settings.glyphLanguage"
        static let emojiStyle = "settings.emojiStyle"
        static let avatarShape = "settings.avatarShape"
        static let animatesAvatars = "settings.animatesAvatars"
        static let animatesCustomEmojis = "settings.animatesCustomEmojis"
        static let linkCardThumbnailSide = "settings.linkCardThumbnailSide"
        static let mediaArrangement = "settings.mediaArrangement"
        static let tiltsStackedPhotos = "settings.tiltsStackedPhotos"
        static let insertionMotion = "settings.insertionMotion"
        static let profileShowsReplies = "settings.profileShowsReplies"
        static let profileShowsBoosts = "settings.profileShowsBoosts"
        static let linkBrowser = "settings.linkBrowser"
        static let reblogVisibility = "settings.reblogVisibility"
        static let statusMenuLayout = "settings.statusMenuLayout"
        static let userMenuLayout = "settings.userMenuLayout"
        static let linkMenuLayout = "settings.linkMenuLayout"
        static let externalPostMenuLayout = "settings.externalPostMenuLayout"
        static let profileTextMenuLayout = "settings.profileTextMenuLayout"
        static let hashtagMenuLayout = "settings.hashtagMenuLayout"
        static let mediaMenuLayout = "settings.mediaMenuLayout"
        static let composeToolLayout = "settings.composeToolLayout"
        static let statusActions = "settings.objectActions.status"
        static let notificationActions = "settings.objectActions.notification"
        static let userActions = "settings.objectActions.user"
        static let linkActions = "settings.objectActions.link"
        static let externalPostActions = "settings.objectActions.externalPost"
        static let hashtagActions = "settings.objectActions.hashtag"
        static let mediaActions = "settings.objectActions.media"
        /// `AccountScopedDefaults`で、アカウントごとのキーにする名前。
        static let tabLayout = "tabLayout"
        static let switchTabItem = "switchTabItem"
        static let hidesEmptyComposeBar = "settings.hidesEmptyComposeBar"
        static let imageUploadSize = "settings.imageUploadSize"
        static let videoUploadSize = "settings.videoUploadSize"
        static let mediaDynamicRange = "settings.mediaDynamicRange"
        static let viewerMediaDynamicRange = "settings.viewerMediaDynamicRange"
        static let drawsReactionGlowInHDR = "settings.drawsReactionGlowInHDR"
        static let reactionGlowIcons = "settings.reactionGlowIcons"
        static let reactionGlowFillsWidthWhenAlone = "settings.reactionGlowFillsWidthWhenAlone"
        static let reactionGlowLightFavouriteColor = "settings.reactionGlowLightFavouriteColor"

        static func appearance(_ id: String) -> String {
            "settings.appearance.\(id)"
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        usesOriginalThumbnailsOnExpensiveNetwork = defaults.object(forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) as? Bool ?? true
        ignoresUselessAltText = defaults.object(forKey: Keys.ignoresUselessAltText) as? Bool ?? true
        showsStatusBarTicker = defaults.object(forKey: Keys.showsStatusBarTicker) as? Bool ?? true
        statusNameStyle = defaults.string(forKey: Keys.statusNameStyle).flatMap(StatusNameStyle.init(rawValue:)) ?? AppearanceDefaults.statusNameStyle
        statusTimeStyle = defaults.string(forKey: Keys.statusTimeStyle).flatMap(StatusTimeStyle.init(rawValue:)) ?? AppearanceDefaults.statusTimeStyle
        contextNameStyle = defaults.string(forKey: Keys.contextNameStyle).flatMap(StatusNameStyle.init(rawValue:)) ?? AppearanceDefaults.contextNameStyle
        showsVisibilitySymbol = defaults.object(forKey: Keys.showsVisibilitySymbol) as? Bool ?? AppearanceDefaults.showsVisibilitySymbol
        showsEditedMark = defaults.object(forKey: Keys.showsEditedMark) as? Bool ?? AppearanceDefaults.showsEditedMark
        showsLinkCardSite = defaults.object(forKey: Keys.showsLinkCardSite) as? Bool ?? AppearanceDefaults.showsLinkCardSite
        showsContextSymbol = defaults.object(forKey: Keys.showsContextSymbol) as? Bool ?? AppearanceDefaults.showsContextSymbol
        boldsName = defaults.object(forKey: Keys.boldsName) as? Bool ?? AppearanceDefaults.boldsName
        showsAvatarBorder = defaults.object(forKey: Keys.showsAvatarBorder) as? Bool ?? AppearanceDefaults.showsAvatarBorder
        showsMediaBadges = defaults.object(forKey: Keys.showsMediaBadges) as? Bool ?? AppearanceDefaults.showsMediaBadges
        showsLinkCard = defaults.object(forKey: Keys.showsLinkCard) as? Bool ?? AppearanceDefaults.showsLinkCard
        boldsLinkCardTitle = defaults.object(forKey: Keys.boldsLinkCardTitle) as? Bool ?? AppearanceDefaults.boldsLinkCardTitle
        showsSeparators = defaults.object(forKey: Keys.showsSeparators) as? Bool ?? AppearanceDefaults.showsSeparators
        showsBoosterAvatar = defaults.object(forKey: Keys.showsBoosterAvatar) as? Bool ?? AppearanceDefaults.showsBoosterAvatar
        showsReplyLabel = defaults.object(forKey: Keys.showsReplyLabel) as? Bool ?? AppearanceDefaults.showsReplyLabel
        showsReplyLines = defaults.object(forKey: Keys.showsReplyLines) as? Bool ?? AppearanceDefaults.showsReplyLines
        showsTime = defaults.object(forKey: Keys.showsTime) as? Bool ?? AppearanceDefaults.showsTime
        showsLinkCardImage = defaults.object(forKey: Keys.showsLinkCardImage) as? Bool ?? AppearanceDefaults.showsLinkCardImage
        glyphLanguage = defaults.string(forKey: Keys.glyphLanguage).flatMap(GlyphLanguage.init(rawValue:)) ?? AppearanceDefaults.glyphLanguage
        emojiStyle = defaults.string(forKey: Keys.emojiStyle).flatMap(EmojiStyle.init(rawValue:)) ?? AppearanceDefaults.emojiStyle
        avatarShape = defaults.string(forKey: Keys.avatarShape).flatMap(AvatarShape.init(rawValue:)) ?? AppearanceDefaults.avatarShape
        animatesAvatars = defaults.object(forKey: Keys.animatesAvatars) as? Bool ?? AppearanceDefaults.animatesAvatars
        animatesCustomEmojis = defaults.object(forKey: Keys.animatesCustomEmojis) as? Bool ?? AppearanceDefaults.animatesCustomEmojis
        linkCardThumbnailSide = defaults.string(forKey: Keys.linkCardThumbnailSide).flatMap(LinkCardThumbnailSide.init(rawValue:)) ?? AppearanceDefaults.linkCardThumbnailSide
        mediaArrangement = defaults.string(forKey: Keys.mediaArrangement).flatMap(MediaArrangement.init(rawValue:)) ?? AppearanceDefaults.mediaArrangement
        tiltsStackedPhotos = defaults.object(forKey: Keys.tiltsStackedPhotos) as? Bool ?? AppearanceDefaults.tiltsStackedPhotos
        insertionMotion = defaults.string(forKey: Keys.insertionMotion).flatMap(InsertionMotion.init(rawValue:)) ?? .followsSystem
        linkBrowser = defaults.string(forKey: Keys.linkBrowser).flatMap(LinkBrowser.init(rawValue:)) ?? .external
        reblogVisibility = defaults.string(forKey: Keys.reblogVisibility).flatMap(ReblogVisibility.init(rawValue:)) ?? .accountDefault
        statusMenuLayout = defaults.stringArray(forKey: Keys.statusMenuLayout).map(MenuLayout.init(tokens:)) ?? StatusMenuItem.defaultLayout
        userMenuLayout = defaults.stringArray(forKey: Keys.userMenuLayout).map(MenuLayout.init(tokens:)) ?? UserMenuItem.defaultLayout
        linkMenuLayout = defaults.stringArray(forKey: Keys.linkMenuLayout).map(MenuLayout.init(tokens:)) ?? LinkMenuItem.defaultLayout
        externalPostMenuLayout = defaults.stringArray(forKey: Keys.externalPostMenuLayout).map(MenuLayout.init(tokens:)) ?? ExternalPostMenuItem.defaultLayout
        profileTextMenuLayout = defaults.stringArray(forKey: Keys.profileTextMenuLayout).map(MenuLayout.init(tokens:)) ?? ProfileTextMenuItem.defaultLayout
        hashtagMenuLayout = defaults.stringArray(forKey: Keys.hashtagMenuLayout).map(MenuLayout.init(tokens:)) ?? HashtagMenuItem.defaultLayout
        mediaMenuLayout = defaults.stringArray(forKey: Keys.mediaMenuLayout).map(MenuLayout.init(tokens:)) ?? MediaMenuItem.defaultLayout
        composeToolLayout = defaults.stringArray(forKey: Keys.composeToolLayout).map(MenuLayout.init(tokens:)) ?? ComposeToolItem.defaultLayout
        statusActions = defaults.stringArray(forKey: Keys.statusActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        notificationActions = defaults.stringArray(forKey: Keys.notificationActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        userActions = defaults.stringArray(forKey: Keys.userActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        linkActions = defaults.stringArray(forKey: Keys.linkActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        externalPostActions = defaults.stringArray(forKey: Keys.externalPostActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        hashtagActions = defaults.stringArray(forKey: Keys.hashtagActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        mediaActions = defaults.stringArray(forKey: Keys.mediaActions).map { ObjectActions(tokens: $0, default: .standard) } ?? .standard
        tabLayouts = AccountScopedDefaults.accountValues(named: Keys.tabLayout, in: defaults).compactMapValues { ($0 as? [String]).map(MenuLayout.init(tokens:)) }
        switchTabItems = AccountScopedDefaults.accountValues(named: Keys.switchTabItem, in: defaults).compactMapValues { ($0 as? String).flatMap(TabItem.init(rawValue:)) }
        hidesEmptyComposeBar = defaults.object(forKey: Keys.hidesEmptyComposeBar) as? Bool ?? false
        // iPhoneの標準の写真（4032×3024）と動画（1080p）はそのまま送られ、それより大きな写真と4Kの動画だけが縮む。
        imageUploadSize = defaults.string(forKey: Keys.imageUploadSize).flatMap(ImageUploadSize.init(rawValue:)) ?? .long4096
        videoUploadSize = defaults.string(forKey: Keys.videoUploadSize).flatMap(VideoUploadSize.init(rawValue:)) ?? .p1080
        mediaDynamicRange = defaults.string(forKey: Keys.mediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .standard
        viewerMediaDynamicRange = defaults.string(forKey: Keys.viewerMediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .constrainedHigh
        drawsReactionGlowInHDR = defaults.object(forKey: Keys.drawsReactionGlowInHDR) as? Bool ?? AppearanceDefaults.drawsReactionGlowInHDR
        reactionGlowIcons = defaults.string(forKey: Keys.reactionGlowIcons).flatMap(ReactionGlowIcons.init(rawValue:)) ?? AppearanceDefaults.reactionGlowIcons
        reactionGlowFillsWidthWhenAlone = defaults.object(forKey: Keys.reactionGlowFillsWidthWhenAlone) as? Bool ?? AppearanceDefaults.reactionGlowFillsWidthWhenAlone
        reactionGlowLightFavouriteColor = defaults.string(forKey: Keys.reactionGlowLightFavouriteColor).flatMap(ReactionGlowLightFavouriteColor.init(rawValue:)) ?? AppearanceDefaults.reactionGlowLightFavouriteColor
        var appearanceValues: [String: Double] = [:]
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            if let stored = defaults.object(forKey: Keys.appearance(item.id)) as? Double, item.range.contains(stored) {
                appearanceValues[item.id] = stored
            }
        }
        self.appearanceValues = appearanceValues
        profilePostsFilter = ProfilePostsFilter(
            showsReplies: defaults.object(forKey: Keys.profileShowsReplies) as? Bool ?? ProfilePostsFilter.standard.showsReplies,
            showsBoosts: defaults.object(forKey: Keys.profileShowsBoosts) as? Bool ?? ProfilePostsFilter.standard.showsBoosts
        )
    }
}

/// 「投稿の見た目」の選択肢の既定値。読み込むときと、まとめて既定に戻すときで同じ値を使う。
private enum AppearanceDefaults {
    static let statusNameStyle: StatusNameStyle = .nameAndAcct
    static let statusTimeStyle: StatusTimeStyle = .relative
    static let contextNameStyle: StatusNameStyle = .nameOnly
    static let glyphLanguage: GlyphLanguage = .automatic
    static let emojiStyle: EmojiStyle = .system
    static let avatarShape: AvatarShape = .roundedSquare
    static let linkCardThumbnailSide: LinkCardThumbnailSide = .left
    static let mediaArrangement: MediaArrangement = .belowBody
    static let tiltsStackedPhotos = true
    static let showsVisibilitySymbol = true
    static let showsEditedMark = true
    static let showsLinkCardSite = true
    static let showsContextSymbol = true
    static let boldsName = true
    static let showsAvatarBorder = true
    static let showsMediaBadges = true
    static let showsLinkCard = true
    static let boldsLinkCardTitle = true
    static let showsSeparators = true
    static let showsBoosterAvatar = true
    static let showsReplyLabel = true
    static let showsReplyLines = true
    static let showsTime = true
    static let showsLinkCardImage = true
    static let animatesAvatars = false
    static let animatesCustomEmojis = false
    static let drawsReactionGlowInHDR = true
    static let reactionGlowIcons: ReactionGlowIcons = .none
    static let reactionGlowFillsWidthWhenAlone = false
    static let reactionGlowLightFavouriteColor: ReactionGlowLightFavouriteColor = .orange
}
