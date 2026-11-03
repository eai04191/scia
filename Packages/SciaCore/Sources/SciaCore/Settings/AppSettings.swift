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

    /// 最上部で新着に追従しているとき、新着を足してから最上部へ動かして見せるか。最上部より下で読んでいるときは、読んでいる位置を保つため動かさない。
    public var insertionMotion: InsertionMotion {
        didSet { defaults.set(insertionMotion.rawValue, forKey: Keys.insertionMotion) }
    }

    /// ボタンやリンクに付けるアクセントカラー。
    public var accentColor: AccentColorChoice {
        didSet { defaults.set(accentColor.rawValue, forKey: Keys.accentColor) }
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

    /// アプリ内のSafariを中くらいの高さで出すときのシートの高さ。
    public var inAppBrowserHeight: InAppBrowserHeight {
        didSet { defaults.set(inAppBrowserHeight.spaceAbove, forKey: Keys.inAppBrowserSpaceAbove) }
    }

    /// アプリ内のSafariを最初から全画面で開くか。オフなら`inAppBrowserHeight`の高さで開く。
    public var opensInAppBrowserFullScreen: Bool {
        didSet { defaults.set(opensInAppBrowserFullScreen, forKey: Keys.opensInAppBrowserFullScreen) }
    }

    /// メニューの「ブースト」でブーストするときの公開範囲。
    public var reblogVisibility: ReblogVisibility {
        didSet { defaults.set(reblogVisibility.rawValue, forKey: Keys.reblogVisibility) }
    }

    /// 「投稿の見た目」の選択肢。まとめて1つのキーに保存する。
    public var appearance: AppearanceChoices {
        didSet { defaults.set(appearance.storedData, forKey: Keys.appearanceChoices) }
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
        AppearanceCatalog.values.contains(where: isModified) || appearance != AppearanceChoices()
    }

    /// 「投稿の見た目」の数値と選択肢を、すべて既定値へ戻す。
    public func resetAppearance() {
        reset(AppearanceCatalog.values)
        appearance = AppearanceChoices()
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

    /// アカウントごとの、最後に見ていたタブの項目。切り替えタブの中なら、開いていた項目。キーはアカウントのハンドル。
    /// 起動したときに、この項目を開く。タブを移るたびに書くので、変更を購読させない。
    @ObservationIgnored private var shownTabItems: [String: TabItem]

    public func shownTabItem(for account: String) -> TabItem? {
        shownTabItems[account]
    }

    public func setShownTabItem(_ item: TabItem, for account: String) {
        guard shownTabItems[account] != item else { return }
        shownTabItems[account] = item
        defaults.set(item.rawValue, forKey: AccountScopedDefaults.key(Keys.shownTabItem, account: account))
    }

    /// ログアウトしたアカウントの並びと最後に開いた項目を忘れる。保存したキーは`AccountScopedDefaults.removeData`が消す。
    func forgetAccount(_ account: String) {
        tabLayouts[account] = nil
        switchTabItems[account] = nil
        shownTabItems[account] = nil
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

    /// 投稿欄の部品を足す項目の並び。どれをツールバーに常に出し、どれを＋のメニューに入れるか。
    public var composeToolLayout: MenuLayout<ComposeToolItem> {
        didSet { defaults.set(composeToolLayout.tokens, forKey: Keys.composeToolLayout) }
    }

    /// 切り替えタブのメニューに、タブの設定の画面を開く「カスタマイズ」を出す。タブの並びの項目はどれもタブになるため、並びに載せず、ここで出すかを決める。
    /// 決まりはdocs/tabs.mdにある。
    public var showsTabMenuCustomize: Bool {
        didSet { defaults.set(showsTabMenuCustomize, forKey: Keys.showsTabMenuCustomize) }
    }

    /// 書いていないときに、空の投稿欄を隠す。書くときは、一覧の右上のボタンで出す。
    /// 下書きや返信先があるときは、残っていると分かるよう隠さない。
    public var hidesEmptyComposeBar: Bool {
        didSet { defaults.set(hidesEmptyComposeBar, forKey: Keys.hidesEmptyComposeBar) }
    }

    /// 書いていないときも投稿欄を細いカプセルに畳まず、書いているときの形で出しておく。
    /// 畳むのは一覧を広く使うためで、画面の広いMacやiPadでは、押した投稿欄が広がって、押した位置にボタンが来てしまうのを避けたいため。
    /// 既定は初期化子で渡す。Macでは、書き始めても欄がその場で広がるので、既定で畳まない。
    public var keepsComposeBarOpen: Bool {
        didSet { defaults.set(keepsComposeBarOpen, forKey: Keys.keepsComposeBarOpen) }
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

    /// ビューアで、HDRのメディアを描く明るさ。
    public var viewerMediaDynamicRange: MediaDynamicRange {
        didSet { defaults.set(viewerMediaDynamicRange.rawValue, forKey: Keys.viewerMediaDynamicRange) }
    }

    /// 保存した値から、アプリ内のSafariの高さを読む。数でない値（NaNや無限大）は刻みに寄せられないので、保存していないときと同じく標準にする。
    private static func inAppBrowserHeight(stored: Any?) -> InAppBrowserHeight {
        guard let space = stored as? Double, space.isFinite else { return .standard }
        return InAppBrowserHeight(spaceAbove: space)
    }

    private enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "settings.usesOriginalThumbnailsOnExpensiveNetwork"
        static let ignoresUselessAltText = "settings.ignoresUselessAltText"
        static let showsStatusBarTicker = "settings.showsStatusBarTicker"
        static let appearanceChoices = "settings.appearanceChoices"
        static let insertionMotion = "settings.insertionMotion"
        static let accentColor = "settings.accentColor"
        static let profileShowsReplies = "settings.profileShowsReplies"
        static let profileShowsBoosts = "settings.profileShowsBoosts"
        static let linkBrowser = "settings.linkBrowser"
        static let inAppBrowserSpaceAbove = "settings.inAppBrowserSpaceAbove"
        static let opensInAppBrowserFullScreen = "settings.opensInAppBrowserFullScreen"
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
        static let shownTabItem = "shownTabItem"
        static let hidesEmptyComposeBar = "settings.hidesEmptyComposeBar"
        static let keepsComposeBarOpen = "settings.keepsComposeBarOpen"
        static let showsTabMenuCustomize = "settings.showsTabMenuCustomize"
        static let imageUploadSize = "settings.imageUploadSize"
        static let videoUploadSize = "settings.videoUploadSize"
        static let mediaDynamicRange = "settings.mediaDynamicRange"
        static let viewerMediaDynamicRange = "settings.viewerMediaDynamicRange"

        static func appearance(_ id: String) -> String {
            "settings.appearance.\(id)"
        }
    }

    /// - Parameter keepsComposeBarOpenByDefault: 使う人が選んでいないときの`keepsComposeBarOpen`。端末で決まるので、アプリが渡す。
    public init(defaults: UserDefaults, keepsComposeBarOpenByDefault: Bool = false) {
        self.defaults = defaults
        usesOriginalThumbnailsOnExpensiveNetwork = defaults.object(forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) as? Bool ?? true
        ignoresUselessAltText = defaults.object(forKey: Keys.ignoresUselessAltText) as? Bool ?? true
        showsStatusBarTicker = defaults.object(forKey: Keys.showsStatusBarTicker) as? Bool ?? true
        appearance = AppearanceChoices(stored: defaults.data(forKey: Keys.appearanceChoices))
        insertionMotion = defaults.string(forKey: Keys.insertionMotion).flatMap(InsertionMotion.init(rawValue:)) ?? .followsSystem
        accentColor = defaults.string(forKey: Keys.accentColor).flatMap(AccentColorChoice.init(rawValue:)) ?? .blue
        linkBrowser = defaults.string(forKey: Keys.linkBrowser).flatMap(LinkBrowser.init(rawValue:)) ?? .inApp
        inAppBrowserHeight = Self.inAppBrowserHeight(stored: defaults.object(forKey: Keys.inAppBrowserSpaceAbove))
        opensInAppBrowserFullScreen = defaults.bool(forKey: Keys.opensInAppBrowserFullScreen)
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
        shownTabItems = AccountScopedDefaults.accountValues(named: Keys.shownTabItem, in: defaults).compactMapValues { ($0 as? String).flatMap(TabItem.init(rawValue:)) }
        hidesEmptyComposeBar = defaults.object(forKey: Keys.hidesEmptyComposeBar) as? Bool ?? false
        keepsComposeBarOpen = defaults.object(forKey: Keys.keepsComposeBarOpen) as? Bool ?? keepsComposeBarOpenByDefault
        showsTabMenuCustomize = defaults.object(forKey: Keys.showsTabMenuCustomize) as? Bool ?? true
        // iPhoneの標準の写真（4032×3024）と動画（1080p）はそのまま送られ、それより大きな写真と4Kの動画だけが縮む。
        imageUploadSize = defaults.string(forKey: Keys.imageUploadSize).flatMap(ImageUploadSize.init(rawValue:)) ?? .long4096
        videoUploadSize = defaults.string(forKey: Keys.videoUploadSize).flatMap(VideoUploadSize.init(rawValue:)) ?? .p1080
        mediaDynamicRange = defaults.string(forKey: Keys.mediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .standard
        viewerMediaDynamicRange = defaults.string(forKey: Keys.viewerMediaDynamicRange).flatMap(MediaDynamicRange.init(rawValue:)) ?? .constrainedHigh
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
    static let wrapsBelowAvatar = false
    static let stacksNameParts = false
    static let showsTime = true
    static let showsLinkCardImage = true
    static let animatesAvatars = false
    static let animatesCustomEmojis = false
    static let drawsReactionGlowInHDR = true
    static let reactionGlowIcons: ReactionGlowIcons = .none
    static let reactionGlowFillsWidthWhenAlone = false
    static let reactionGlowLightFavouriteColor: ReactionGlowLightFavouriteColor = .orange
}
