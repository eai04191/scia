public import Foundation
public import Observation

/// 使う人が設定画面で選ぶ値。変更はObservationで購読できる。
/// プリセットに含める値は、`target`が指すプリセットから読み、そこへ書く。含めない値は、端末に1つの`SettingsStore`に読み書きする（docs/preset.md）。
/// 同じ`SettingsStore`を共有する`AppSettings`を、アプリ（`AppDependencies.settings`）と、窓に開いたアカウントごと（`forAccount(_:)`）に作る。
@MainActor
@Observable
public final class AppSettings {
    /// 値を読み書きするプリセットを、どう決めるか。
    public enum Target: Hashable, Sendable {
        /// アプリかアカウントが使うプリセット。組み込みのプリセットを使っているときに値を変えると、それを親にしたプリセットを作って切り替える。
        case scope(PresetScope)
        /// プリセットを選ぶ画面から開いた、決まったプリセット。
        case preset(PresetID)
    }

    @ObservationIgnored public let store: SettingsStore
    @ObservationIgnored public let target: Target
    /// 組み込みのプリセットを使っているときに値を変え、それを親にしたプリセットを作って切り替えたときに、作ったプリセットを渡す（docs/preset.md）。
    @ObservationIgnored public var onPresetCreated: (@MainActor (PresetID) -> Void)?

    /// - Parameter keepsComposeBarOpenByDefault: 使う人が選んでいないときの`keepsComposeBarOpen`。端末で決まるので、アプリが渡す。
    public convenience init(defaults: UserDefaults, keepsComposeBarOpenByDefault: Bool = false) {
        self.init(store: SettingsStore(defaults: defaults, keepsComposeBarOpenByDefault: keepsComposeBarOpenByDefault), target: .scope(.app))
        LegacySettingsMigration.migrate(into: self, defaults: defaults)
    }

    public init(store: SettingsStore, target: Target) {
        self.store = store
        self.target = target
    }

    /// 同じ保存先を共有し、アカウントが使うプリセットを読み書きする設定。
    public func forAccount(_ handle: String) -> AppSettings {
        AppSettings(store: store, target: .scope(.account(handle)))
    }

    /// 同じ保存先を共有し、決まったプリセットを読み書きする設定。
    public func editing(_ preset: PresetID) -> AppSettings {
        AppSettings(store: store, target: .preset(preset))
    }

    /// 値を読むプリセット。
    public var presetID: PresetID {
        switch target {
        case .scope(let scope):
            store.trackSelection()
            return store.library.preset(for: scope)
        case .preset(let id):
            return id
        }
    }

    /// 変えた項目を戻したときに従う、親のプリセットの名前。組み込みのプリセットは親を持たないので、そのプリセットの名前。
    public var parentPresetName: String {
        let library = store.observedLibrary
        let preset = presetID
        let parent = library.ancestors(of: preset).first ?? preset
        return library.name(of: parent) ?? ""
    }

    /// 表示しているアカウント。アプリの設定と、決まったプリセットの設定ではnil。
    private var account: String? {
        guard case .scope(.account(let handle)) = target else { return nil }
        return handle
    }

    // MARK: プリセットに含める値

    /// モバイル通信とインターネット共有でも、タイムラインのサムネイルに元の画像を読む。
    /// オフなら、サーバーが縮めたプレビュー画像を読む。
    public var usesOriginalThumbnailsOnExpensiveNetwork: Bool {
        get { bool(Keys.usesOriginalThumbnailsOnExpensiveNetwork, default: true) }
        set { write(.bool(newValue), Keys.usesOriginalThumbnailsOnExpensiveNetwork) }
    }

    /// 「undefined」や「Screenshot」のような、説明にならない代替テキストを付いていないものとして扱う。
    public var ignoresUselessAltText: Bool {
        get { bool(Keys.ignoresUselessAltText, default: true) }
        set { write(.bool(newValue), Keys.ignoresUselessAltText) }
    }

    /// プロフィールの自己紹介を、折りたたむか、最初から全文を出すか。
    public var profileNoteLength: ProfileNoteLength {
        get { choice(Keys.profileNoteLength, default: .collapsed) }
        set { write(.text(newValue.rawValue), Keys.profileNoteLength) }
    }

    /// プロフィールの固定された投稿を、タイムラインの上の棚に分けて出す。オフなら、投稿のタイムラインの先頭に並べる。
    public var separatesProfilePinned: Bool {
        get { bool(Keys.separatesProfilePinned, default: true) }
        set { write(.bool(newValue), Keys.separatesProfilePinned) }
    }

    /// プロフィールに、注目のハッシュタグの棚を出す。オフなら読み込まない。
    public var showsProfileFeaturedTags: Bool {
        get { bool(Keys.showsProfileFeaturedTags, default: true) }
        set { write(.bool(newValue), Keys.showsProfileFeaturedTags) }
    }

    /// プロフィールに、紹介しているユーザーの棚を出す。オフなら読み込まない。
    public var showsProfileEndorsements: Bool {
        get { bool(Keys.showsProfileEndorsements, default: true) }
        set { write(.bool(newValue), Keys.showsProfileEndorsements) }
    }

    /// プロフィールの補足情報のカード、固定された投稿のカード、フォローのボタン、画面のティントカラーを、アイコンから取った色で塗る。
    /// オフなら、システムの色とアプリのアクセントカラーのままにする。
    public var usesDynamicProfileAccent: Bool {
        get { bool(Keys.usesDynamicProfileAccent, default: true) }
        set { write(.bool(newValue), Keys.usesDynamicProfileAccent) }
    }

    /// Xの投稿へのリンクを、fxtwitterから読んだ作者、本文、添付ファイルの囲みで出す。
    /// 表示しただけでSciaと関係のないfxtwitterとXに通信するので、既定はオフにし、使う人がオンにしたときだけ通信する（docs/link-card.md）。
    /// 組み込みのプリセットはこの値を持たない（docs/preset.md）。
    public var expandsXPosts: Bool {
        get { bool(Keys.expandsXPosts, default: false) }
        set { write(.bool(newValue), Keys.expandsXPosts) }
    }

    /// タイムラインの本文を自動で訳す（docs/auto-translation.md）。
    public var isAutoTranslationEnabled: Bool {
        get { bool(Keys.isAutoTranslationEnabled, default: false) }
        set { write(.bool(newValue), Keys.isAutoTranslationEnabled) }
    }

    /// 自動翻訳がオンなら、訳す投稿の言語。オフなら空。
    public var effectiveAutoTranslationLanguages: [String] {
        isAutoTranslationEnabled ? autoTranslationLanguages : []
    }

    /// 翻訳の言語モデルが入るたびに増える。増えたら、モデルがなくて訳せなかった投稿を訳し直す。保存しない。
    public var autoTranslationModelRevision: Int { store.autoTranslationModelRevision }

    public func noteAutoTranslationModelInstalled() {
        store.autoTranslationModelRevision += 1
    }

    /// タイムラインの本文を自動で訳す投稿の言語。空なら訳さない（docs/auto-translation.md）。
    /// プリセットに含めない。言語のモデルが入っているものだけ選べ、端末の状態で選べるものが変わるため（docs/preset.md）。
    public var autoTranslationLanguages: [String] {
        get { store.autoTranslationLanguages }
        set { store.autoTranslationLanguages = newValue }
    }

    /// 自動翻訳の対象外にした人のハンドル（`username@domain`）。対象外にした順（docs/auto-translation.md）。
    /// プリセットに含めない。値が設定ではなく、溜めたデータのため（docs/preset.md）。
    public var autoTranslationExcludedHandles: [String] {
        get { store.autoTranslationExcludedHandles }
        set { store.autoTranslationExcludedHandles = newValue }
    }

    /// 同じサーバーの人は、ログインしたアドレスのサーバー名を補ったハンドルで比べる。どのアカウントから見ても同じ人を同じハンドルで指すため。
    /// ユーザーのIDにアドレスと別のドメイン（`LOCAL_DOMAIN`）を使うサーバーでは、そのサーバーのアカウントで対象外にした同じサーバーの人が、ほかのサーバーのアカウントから見たハンドルと一致せず、そちらでは訳される。
    /// そろえるには`api/v2/instance`の`domain`を持ち回る必要があり、`Credential.handle(ofAcct:)`と同じく読んでいない。
    /// - Parameter localServer: ログインしているサーバーの名前。`acct`にサーバー名がないときに補う。
    public func isExcludedFromAutoTranslation(acct: String, localServer: String) -> Bool {
        let handle = UserHandle(acct: acct, localServer: localServer).fullAcct.lowercased()
        return autoTranslationExcludedHandles.contains { $0.lowercased() == handle }
    }

    public func setExcludedFromAutoTranslation(_ isExcluded: Bool, acct: String, localServer: String) {
        let handle = UserHandle(acct: acct, localServer: localServer).fullAcct
        autoTranslationExcludedHandles.removeAll { $0.lowercased() == handle.lowercased() }
        if isExcluded { autoTranslationExcludedHandles.append(handle) }
    }

    /// 自動翻訳の翻訳先の言語の識別子。nilならデバイスの言語（docs/auto-translation.md）。
    public var autoTranslationTarget: String? {
        get {
            switch value(Keys.autoTranslationTarget) {
            case .text(let identifier): identifier
            default: nil
            }
        }
        set { write(newValue.map(PresetValue.text) ?? .null, Keys.autoTranslationTarget) }
    }

    /// 自動翻訳の翻訳の方式（docs/auto-translation.md）。
    /// プリセットに含めない。Apple Intelligenceを使える端末だけ選べ、端末の状態で選べるものが変わるため（docs/preset.md）。
    public var autoTranslationStrategy: TranslationStrategy {
        get { store.autoTranslationStrategy }
        set { store.autoTranslationStrategy = newValue }
    }

    /// 届いた通知を、ステータスバーの場所に流す。
    public var showsStatusBarTicker: Bool {
        get { bool(Keys.showsStatusBarTicker, default: true) }
        set { write(.bool(newValue), Keys.showsStatusBarTicker) }
    }

    /// 最上部で新着に追従しているとき、新着を足してから最上部へ動かして見せるか。最上部より下で読んでいるときは、読んでいる位置を保つため動かさない。
    public var insertionMotion: InsertionMotion {
        get { choice(Keys.insertionMotion, default: .followsSystem) }
        set { write(.text(newValue.rawValue), Keys.insertionMotion) }
    }

    /// ボタンやリンクに付けるアクセントカラー。
    public var accentColor: AccentColorChoice {
        get { choice(Keys.accentColor, default: .blue) }
        set { write(.text(newValue.rawValue), Keys.accentColor) }
    }

    /// プロフィール画面の「投稿」に、返信とブーストを混ぜるか。どのアカウントのプロフィールにも効かせる。
    /// プリセットに含めない。設定の画面の外で、使っているうちに変わるため（docs/preset.md）。
    public var profilePostsFilter: ProfilePostsFilter {
        get { store.profilePostsFilter }
        set { store.profilePostsFilter = newValue }
    }

    /// 本文のURLのリンクを、既定のブラウザとアプリ内のSafariのどちらで開くか。
    public var linkBrowser: LinkBrowser {
        get { choice(Keys.linkBrowser, default: .inApp) }
        set { write(.text(newValue.rawValue), Keys.linkBrowser) }
    }

    /// 絵文字のパレットと補完で、肌の色を変えられる絵文字に付ける既定の肌の色。決まりはdocs/compose.mdの「絵文字の肌の色」にある。
    /// プリセットに含めない。設定の画面の外で、使っているうちに変わるため（docs/preset.md）。
    public var emojiSkinTone: EmojiSkinTone {
        get { store.emojiSkinTone }
        set { store.emojiSkinTone = newValue }
    }

    /// アプリ内のSafariを中くらいの高さで出すときのシートの高さ。
    /// 数でない値（NaNや無限大）は刻みに寄せられないので、持っていないときと同じく標準にする。
    public var inAppBrowserHeight: InAppBrowserHeight {
        get {
            guard let space = number(Keys.inAppBrowserSpaceAbove), space.isFinite else { return .standard }
            return InAppBrowserHeight(spaceAbove: space)
        }
        set { write(.number(newValue.spaceAbove), Keys.inAppBrowserSpaceAbove) }
    }

    /// アプリ内のSafariを最初から全画面で開くか。オフなら`inAppBrowserHeight`の高さで開く。
    public var opensInAppBrowserFullScreen: Bool {
        get { bool(Keys.opensInAppBrowserFullScreen, default: false) }
        set { write(.bool(newValue), Keys.opensInAppBrowserFullScreen) }
    }

    /// メニューの「ブースト」でブーストするときの公開範囲。
    public var reblogVisibility: ReblogVisibility {
        get { choice(Keys.reblogVisibility, default: .accountDefault) }
        set { write(.text(newValue.rawValue), Keys.reblogVisibility) }
    }

    /// 「投稿の見た目」の選択肢。選択肢ごとに、プリセットの別々の値として持つ。
    public var appearance: AppearanceChoices {
        get { store.resolvedAppearance(in: presetID) }
        set {
            let current = AppearanceStorage.fields(of: appearance)
            for (field, value) in AppearanceStorage.fields(of: newValue) where current[field] != value {
                write(value, AppearanceStorage.key(field))
            }
        }
    }

    /// 「投稿の見た目」の選択肢の今の値を、親から受け継いだ値と同じでも、読んでいるプリセットの値として書く。
    func pinAppearanceChoice(_ field: String) {
        write(AppearanceStorage.fields(of: appearance)[field] ?? .null, AppearanceStorage.key(field))
    }

    /// 「投稿の見た目」と「通知の見た目」の数値。キーは`AppearanceValue.id`。購読のために読む。
    public var appearanceValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: Self.appearanceItems.map { ($0.id, value(of: $0)) })
    }

    private static let appearanceItems = AppearanceCatalog.values + NotificationAppearanceCatalog.values

    /// 範囲の外の値は、持っていないときと同じく既定値にする。
    public func value(of item: AppearanceValue) -> Double {
        guard let stored = number(Self.appearanceKey(item)), item.range.contains(stored) else { return item.defaultValue }
        return stored
    }

    /// 範囲外の値は範囲内に丸めて保存する。数でない値（NaNや無限）は、行数などを整数に直すところで落ちるため、保存しない。
    public func setValue(_ value: Double, for item: AppearanceValue) {
        guard value.isFinite else { return }
        let clamped = min(max(Self.snapped(value, toMultipleOf: item.step), item.range.lowerBound), item.range.upperBound)
        write(.number(clamped), Self.appearanceKey(item))
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

    /// 読んでいるプリセットが変えた項目か。値が親と同じでも、変えた項目として扱う（docs/preset.md）。
    public func isModified(_ item: AppearanceValue) -> Bool {
        isModified(key: Self.appearanceKey(item))
    }

    public func isModified(_ choice: AppearanceChoice) -> Bool {
        isModified(key: AppearanceStorage.key(choice.field))
    }

    /// 変えたことを取り消し、親のプリセットの値に従わせる。
    public func reset(_ choice: AppearanceChoice) {
        reset(keys: [AppearanceStorage.key(choice.field)])
    }

    /// 「投稿の見た目」の分類の、数値か選択肢のどれかを、読んでいるプリセットが変えたか。
    public func isAppearanceGroupModified(_ group: AppearanceGroup) -> Bool {
        group.values.contains(where: isModified) || AppearanceChoice.choices(inGroup: group.id).contains(where: isModified)
    }

    /// 分類の外に置く「スレッドで開いた投稿はすべて表示」を、読んでいるプリセットが変えたか。
    public var isRevealsAllPartsInThreadModified: Bool {
        isModified(key: AppearanceStorage.key(AppearanceStorage.revealsAllPartsInThread))
    }

    public func resetRevealsAllPartsInThread() {
        reset(keys: [AppearanceStorage.key(AppearanceStorage.revealsAllPartsInThread)])
    }

    public var isAppearanceModified: Bool {
        AppearanceCatalog.values.contains(where: isModified) || AppearanceStorage.fieldNames.contains { isModified(key: AppearanceStorage.key($0)) }
    }

    /// 「投稿の見た目」の数値と選択肢を、すべて親のプリセットの値に従わせる。
    public func resetAppearance() {
        reset(AppearanceCatalog.values)
        reset(keys: AppearanceStorage.fieldNames.map(AppearanceStorage.key))
    }

    /// 「通知の見た目」の数値のどれかを、読んでいるプリセットが変えたか。
    public var isNotificationAppearanceModified: Bool {
        NotificationAppearanceCatalog.values.contains(where: isModified)
    }

    /// 「通知の見た目」の数値を、すべて親のプリセットの値に従わせる。
    public func resetNotificationAppearance() {
        reset(NotificationAppearanceCatalog.values)
    }

    /// 項目を、親のプリセットの値に従わせる。
    public func reset(_ items: [AppearanceValue]) {
        reset(keys: items.map(Self.appearanceKey))
    }

    // MARK: タブ（プリセットに含めない。アカウントに固有のため）

    /// アカウントごとのタブの並び。キーはアカウントのハンドル。保存していないアカウントは既定の並びを使う。
    public var tabLayouts: [String: MenuLayout<TabItem>] { store.tabLayouts }

    /// - Parameter account: アカウントのハンドル（`Credential.handle`）。
    public func tabLayout(for account: String) -> MenuLayout<TabItem> {
        store.tabLayouts[account] ?? TabItem.defaultLayout
    }

    public func setTabLayout(_ layout: MenuLayout<TabItem>, for account: String) {
        store.setTabLayout(layout, for: account)
    }

    public func switchTabItem(for account: String) -> TabItem? {
        store.switchTabItems[account]
    }

    public func setSwitchTabItem(_ item: TabItem, for account: String) {
        store.setSwitchTabItem(item, for: account)
    }

    public func shownTabItem(for account: String) -> TabItem? {
        store.shownTabItems[account]
    }

    public func setShownTabItem(_ item: TabItem, for account: String) {
        store.setShownTabItem(item, for: account)
    }

    // MARK: アニメーション

    /// アイコンのアニメーションを再生するか。「アカウントの設定に従う」（nil）なら、表示しているアカウントのサーバーの設定（`serverAutoplaysAnimations`）に従う。
    public var animatesAvatars: Bool {
        get { appearance.animatesAvatars ?? serverAutoplaysAnimations }
        set { appearance.animatesAvatars = newValue }
    }

    /// カスタム絵文字のアニメーションを再生するか。「アカウントの設定に従う」（nil）なら、表示しているアカウントのサーバーの設定（`serverAutoplaysAnimations`）に従う。
    public var animatesCustomEmojis: Bool {
        get { appearance.animatesCustomEmojis ?? serverAutoplaysAnimations }
        set { appearance.animatesCustomEmojis = newValue }
    }

    /// 表示しているアカウントの、サーバーの設定「アニメーションGIFを自動再生する」（`reading:autoplay:gifs`）。
    /// アカウントの設定は、そのアカウントの覚えた値を読む。アプリの設定は、最後に表示を始めたアカウントの値を読む。
    /// 読めた値を覚えていないアカウントでは、Mastodonの既定と同じくfalseにする。
    public var serverAutoplaysAnimations: Bool {
        guard let account else { return store.lastServerAutoplaysAnimations }
        return store.serverAnimationAutoplays[account] ?? false
    }

    /// 表示を始めるアカウントの、覚えたサーバーの値に従う。
    public func followServerAnimations(of account: String) {
        store.followServerAnimations(of: account)
    }

    /// 読めたサーバーの値を覚える。表示しているアカウントの値なら、すぐ従う。
    public func rememberServerAnimations(_ autoplays: Bool, of account: String) {
        store.rememberServerAnimations(autoplays, of: account)
    }

    /// ログアウトしたアカウントの並び、最後に開いた項目、覚えたサーバーの値、プリセットの割り当てを忘れる。保存したキーは`AccountScopedDefaults.removeData`が消す。
    func forgetAccount(_ account: String) {
        store.forgetAccount(account)
    }

    // MARK: 操作

    /// 投稿を長押しして出すメニューの並び。通知のメニューもこれで組む。
    public var statusMenuLayout: MenuLayout<StatusMenuItem> {
        get { layout(Keys.statusMenuLayout, default: StatusMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.statusMenuLayout) }
    }

    /// 投稿のメニューの中に、ユーザーごとのサブメニューとして出すメニューの並び。
    public var userMenuLayout: MenuLayout<UserMenuItem> {
        get { layout(Keys.userMenuLayout, default: UserMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.userMenuLayout) }
    }

    /// 本文のURLのリンクを長押しして出すメニューの並び。メンションはユーザーのメニューで出す。
    public var linkMenuLayout: MenuLayout<LinkMenuItem> {
        get { layout(Keys.linkMenuLayout, default: LinkMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.linkMenuLayout) }
    }

    /// ほかのサービスの投稿（Xの投稿の囲みなど）を長押しして出すメニューの並び。
    public var externalPostMenuLayout: MenuLayout<ExternalPostMenuItem> {
        get { layout(Keys.externalPostMenuLayout, default: ExternalPostMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.externalPostMenuLayout) }
    }

    /// プロフィールの表示名、自己紹介、補足情報の行を長押しして出すメニューの並び。
    public var profileTextMenuLayout: MenuLayout<ProfileTextMenuItem> {
        get { layout(Keys.profileTextMenuLayout, default: ProfileTextMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.profileTextMenuLayout) }
    }

    public var customEmojiMenuLayout: MenuLayout<CustomEmojiMenuItem> {
        get { layout(Keys.customEmojiMenuLayout, default: CustomEmojiMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.customEmojiMenuLayout) }
    }

    /// 本文のハッシュタグを長押しして出すメニューの並び。
    public var hashtagMenuLayout: MenuLayout<HashtagMenuItem> {
        get { layout(Keys.hashtagMenuLayout, default: HashtagMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.hashtagMenuLayout) }
    }

    /// 投稿の絵文字のリアクションのボタンを長押しして出すメニューの並び。
    public var reactionMenuLayout: MenuLayout<ReactionMenuItem> {
        get { layout(Keys.reactionMenuLayout, default: ReactionMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.reactionMenuLayout) }
    }

    /// メディアを長押ししたときと、ビューアのメニューの並び。
    public var mediaMenuLayout: MenuLayout<MediaMenuItem> {
        get { layout(Keys.mediaMenuLayout, default: MediaMenuItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.mediaMenuLayout) }
    }

    /// 投稿の行をタップ、長押ししたときの操作。決まりはdocs/object-actions.mdにある。
    public var statusActions: ObjectActions<StatusMenuItem> {
        get { actions(Keys.statusActions) }
        set { writeActions(newValue, Keys.statusActions) }
    }

    /// 引用の囲みをタップ、長押ししたときの操作。項目は投稿のメニューから選ぶ。
    public var quotedStatusActions: ObjectActions<StatusMenuItem> {
        get { actions(Keys.quotedStatusActions) }
        set { writeActions(newValue, Keys.quotedStatusActions) }
    }

    /// 通知の行をタップ、長押ししたときの操作。項目は投稿のメニューから選ぶ。
    public var notificationActions: ObjectActions<StatusMenuItem> {
        get { actions(Keys.notificationActions) }
        set { writeActions(newValue, Keys.notificationActions) }
    }

    /// アイコン、「〜がブースト」の行、人のリストの行、メンションをタップ、長押ししたときの操作。
    public var userActions: ObjectActions<UserMenuItem> {
        get { actions(Keys.userActions) }
        set { writeActions(newValue, Keys.userActions) }
    }

    /// URLのリンク、リンクカードをタップ、長押ししたときの操作。
    public var linkActions: ObjectActions<LinkMenuItem> {
        get { actions(Keys.linkActions) }
        set { writeActions(newValue, Keys.linkActions) }
    }

    /// ほかのサービスの投稿（Xの投稿の囲みなど）をタップ、長押ししたときの操作。
    public var externalPostActions: ObjectActions<ExternalPostMenuItem> {
        get { actions(Keys.externalPostActions) }
        set { writeActions(newValue, Keys.externalPostActions) }
    }

    /// ハッシュタグをタップ、長押ししたときの操作。
    public var hashtagActions: ObjectActions<HashtagMenuItem> {
        get { actions(Keys.hashtagActions) }
        set { writeActions(newValue, Keys.hashtagActions) }
    }

    /// 投稿の絵文字のリアクションのボタンをタップ、長押ししたときの操作。
    public var reactionActions: ObjectActions<ReactionMenuItem> {
        get { actions(Keys.reactionActions) }
        set { writeActions(newValue, Keys.reactionActions) }
    }

    /// サムネイル、リンクカードの画像、プロフィールの画像をタップ、長押ししたときの操作。ビューアの中は含めない。
    public var mediaActions: ObjectActions<MediaMenuItem> {
        get { actions(Keys.mediaActions) }
        set { writeActions(newValue, Keys.mediaActions) }
    }

    /// アクションバーに並べるボタンの並び。決まりはdocs/post-action-bar.mdにある。
    public var postActionBarLayout: MenuLayout<PostActionBarItem> {
        get { layout(Keys.postActionBarLayout, default: PostActionBarItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.postActionBarLayout) }
    }

    /// 投稿を右にスワイプして出すボタンの並び（行の先頭の側）。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
    public var postLeadingSwipeLayout: MenuLayout<PostSwipeItem> {
        get { layout(Keys.postLeadingSwipeLayout, default: PostSwipeItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.postLeadingSwipeLayout) }
    }

    /// 投稿を左にスワイプして出すボタンの並び（行の末尾の側）。
    public var postTrailingSwipeLayout: MenuLayout<PostSwipeItem> {
        get { layout(Keys.postTrailingSwipeLayout, default: PostSwipeItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.postTrailingSwipeLayout) }
    }

    /// 投稿のタップ、長押し、スワイプのどれかに「アクションバーを開く」を割り当てているか。
    public var opensActionBarByGesture: Bool {
        statusActions.tap == .actionBar || statusActions.longPress == .actionBar
            || postLeadingSwipeLayout.swipeItems.contains(.actionBar) || postTrailingSwipeLayout.swipeItems.contains(.actionBar)
    }

    /// アクションバーを出している投稿のメニューに、アクションバーに並べた項目も出すか。決まりはdocs/post-action-bar.mdにある。
    public var showsActionBarItemsInMenu: Bool {
        get { bool(Keys.showsActionBarItemsInMenu, default: false) }
        set { write(.bool(newValue), Keys.showsActionBarItemsInMenu) }
    }

    /// アクションバーを出している投稿のメニューに、アクションバーのボタンの長押しで出す項目も出すか。
    public var showsActionBarLongPressItemsInMenu: Bool {
        get { bool(Keys.showsActionBarLongPressItemsInMenu, default: false) }
        set { write(.bool(newValue), Keys.showsActionBarLongPressItemsInMenu) }
    }

    /// 投稿欄の部品を足す項目の並び。どれをツールバーに常に出し、どれを＋のメニューに入れるか。
    public var composeToolLayout: MenuLayout<ComposeToolItem> {
        get { layout(Keys.composeToolLayout, default: ComposeToolItem.defaultLayout) }
        set { write(.list(newValue.tokens), Keys.composeToolLayout) }
    }

    /// 切り替えタブのメニューに、タブの設定の画面を開く「カスタマイズ」を出す。タブの並びの項目はどれもタブになるため、並びに載せず、ここで出すかを決める。
    /// 決まりはdocs/tabs.mdにある。プリセットに含めない。「タブ」の画面に置くため（docs/preset.md）。
    public var showsTabMenuCustomize: Bool {
        get { store.showsTabMenuCustomize }
        set { store.showsTabMenuCustomize = newValue }
    }

    /// 書いていないときに、空の投稿欄を隠す。書くときは、タイムラインの右上のボタンで出す。
    /// 下書きや返信先があるときは、残っていると分かるよう隠さない。
    public var hidesEmptyComposeBar: Bool {
        get { bool(Keys.hidesEmptyComposeBar, default: false) }
        set { write(.bool(newValue), Keys.hidesEmptyComposeBar) }
    }

    /// 書いていないときも投稿欄を細いカプセルに畳まず、書いているときの形で出しておく。
    /// 畳むのはタイムラインを広く使うためで、画面の広いMacやiPadでは、押した投稿欄が広がって、押した位置にボタンが来てしまうのを避けたいため。
    /// 既定は初期化子で渡す。Macでは、書き始めても欄がその場で広がるので、既定で畳まない。
    public var keepsComposeBarOpen: Bool {
        get { bool(Keys.keepsComposeBarOpen, default: store.keepsComposeBarOpenByDefault) }
        set { write(.bool(newValue), Keys.keepsComposeBarOpen) }
    }

    /// 送る前に画像を縮める大きさ。選んだ大きさに収まる画像は元のまま送る。
    /// iPhoneの標準の写真（4032×3024）と動画（1080p）はそのまま送られ、それより大きな写真と4Kの動画だけが縮む。
    public var imageUploadSize: ImageUploadSize {
        get { choice(Keys.imageUploadSize, default: .long4096) }
        set { write(.text(newValue.rawValue), Keys.imageUploadSize) }
    }

    /// 送る前に動画を縮める大きさ。選んだ大きさに収まる動画は元のまま送る。
    public var videoUploadSize: VideoUploadSize {
        get { choice(Keys.videoUploadSize, default: .p1080) }
        set { write(.text(newValue.rawValue), Keys.videoUploadSize) }
    }

    /// ビューアの外（タイムライン、プロフィール、リンクカード、投稿欄のサムネイルなど）で、HDRのメディアを描く明るさ。
    public var mediaDynamicRange: MediaDynamicRange {
        get { choice(Keys.mediaDynamicRange, default: .standard) }
        set { write(.text(newValue.rawValue), Keys.mediaDynamicRange) }
    }

    /// ビューアで、HDRのメディアを描く明るさ。
    public var viewerMediaDynamicRange: MediaDynamicRange {
        get { choice(Keys.viewerMediaDynamicRange, default: .constrainedHigh) }
        set { write(.text(newValue.rawValue), Keys.viewerMediaDynamicRange) }
    }

    // MARK: 読み書き

    private func value(_ key: String) -> PresetValue? {
        store.read(key, in: presetID)
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard case .bool(let value) = value(key) else { return defaultValue }
        return value
    }

    private func number(_ key: String) -> Double? {
        guard case .number(let value) = value(key) else { return nil }
        return value
    }

    private func list(_ key: String) -> [String]? {
        guard case .list(let value) = value(key) else { return nil }
        return value
    }

    /// 読めない値（名前を変えた選択肢など）は、持っていないときと同じく既定値にする。
    private func choice<Value: RawRepresentable<String>>(_ key: String, default defaultValue: Value) -> Value {
        guard case .text(let raw) = value(key) else { return defaultValue }
        return Value(rawValue: raw) ?? defaultValue
    }

    private func layout<Item>(_ key: String, default defaultValue: MenuLayout<Item>) -> MenuLayout<Item> {
        list(key).map(MenuLayout.init(tokens:)) ?? defaultValue
    }

    /// タップと長押しは、別々の値として持つ（docs/preset.md）。読めない操作（なくなった項目など）は、その操作だけ既定に戻す。
    private func actions<Item: ObjectActionItem>(_ key: String) -> ObjectActions<Item> {
        func token(_ suffix: String) -> String {
            guard case .text(let token) = value("\(key).\(suffix)") else { return "" }
            return token
        }
        return ObjectActions(tokens: [token("tap"), token("longPress")], default: .standard)
    }

    /// 変わった操作だけを書く。片方だけを変えたとき、もう片方を変えた項目にしないため。
    private func writeActions<Item: ObjectActionItem>(_ actions: ObjectActions<Item>, _ key: String) {
        let current: ObjectActions<Item> = self.actions(key)
        if actions.tap != current.tap { write(.text(actions.tap.token), "\(key).tap") }
        if actions.longPress != current.longPress { write(.text(actions.longPress.token), "\(key).longPress") }
    }

    /// 読んでいるプリセットへ書く。組み込みのプリセットを使っていれば、それを親にしたプリセットを作って切り替える。
    /// 書く先のプリセットが消えていたら（開いていた編集の画面のプリセットを、ほかで消したときなど）、書く先がないので書かない。
    func write(_ value: PresetValue, _ key: String) {
        var created: PresetID?
        store.updateLibrary { library throws(PresetError) in
            switch target {
            case .scope(let scope):
                let before = library.preset(for: scope)
                let written = try library.setValue(value, forKey: key, for: scope)
                created = written == before ? nil : written
            case .preset(let id): try library.setValue(value, forKey: key, in: id)
            }
        }
        if let created { onPresetCreated?(created) }
    }

    func isModified(key: String) -> Bool {
        let preset = presetID
        store.track(key, in: preset)
        return store.library.isModified(key, in: preset)
    }

    /// 組み込みのプリセットを読んでいるときは、変えた項目がないので何もしない。
    func reset(keys: [String]) {
        let id = presetID
        guard case .user = id else { return }
        store.updateLibrary { library throws(PresetError) in
            for key in keys {
                try library.resetValue(forKey: key, in: id)
            }
        }
    }

    static func appearanceKey(_ item: AppearanceValue) -> String {
        item.presetKey
    }

    /// プリセットに持つ値のキー。
    enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "usesOriginalThumbnailsOnExpensiveNetwork"
        static let showsStatusBarTicker = "showsStatusBarTicker"
        static let expandsXPosts = "expandsXPosts"
        static let profileNoteLength = "profileNoteLength"
        static let separatesProfilePinned = "separatesProfilePinned"
        static let showsProfileFeaturedTags = "showsProfileFeaturedTags"
        static let showsProfileEndorsements = "showsProfileEndorsements"
        static let usesDynamicProfileAccent = "usesDynamicProfileAccent"
        static let isAutoTranslationEnabled = "isAutoTranslationEnabled"
        static let ignoresUselessAltText = "ignoresUselessAltText"
        static let autoTranslationTarget = "autoTranslationTarget"
        static let insertionMotion = "insertionMotion"
        static let accentColor = "accentColor"
        static let linkBrowser = "linkBrowser"
        static let inAppBrowserSpaceAbove = "inAppBrowserSpaceAbove"
        static let opensInAppBrowserFullScreen = "opensInAppBrowserFullScreen"
        static let reblogVisibility = "reblogVisibility"
        static let statusMenuLayout = "statusMenuLayout"
        static let userMenuLayout = "userMenuLayout"
        static let linkMenuLayout = "linkMenuLayout"
        static let externalPostMenuLayout = "externalPostMenuLayout"
        static let profileTextMenuLayout = "profileTextMenuLayout"
        static let customEmojiMenuLayout = "customEmojiMenuLayout"
        static let hashtagMenuLayout = "hashtagMenuLayout"
        static let reactionMenuLayout = "reactionMenuLayout"
        static let mediaMenuLayout = "mediaMenuLayout"
        static let composeToolLayout = "composeToolLayout"
        static let postActionBarLayout = "postActionBarLayout"
        static let postLeadingSwipeLayout = "postLeadingSwipeLayout"
        static let postTrailingSwipeLayout = "postTrailingSwipeLayout"
        static let showsActionBarItemsInMenu = "showsActionBarItemsInMenu"
        static let showsActionBarLongPressItemsInMenu = "showsActionBarLongPressItemsInMenu"
        static let statusActions = "objectActions.status"
        static let quotedStatusActions = "objectActions.quotedStatus"
        static let notificationActions = "objectActions.notification"
        static let userActions = "objectActions.user"
        static let linkActions = "objectActions.link"
        static let externalPostActions = "objectActions.externalPost"
        static let hashtagActions = "objectActions.hashtag"
        static let reactionActions = "objectActions.reaction"
        static let mediaActions = "objectActions.media"
        static let hidesEmptyComposeBar = "hidesEmptyComposeBar"
        static let keepsComposeBarOpen = "keepsComposeBarOpen"
        static let imageUploadSize = "imageUploadSize"
        static let videoUploadSize = "videoUploadSize"
        static let mediaDynamicRange = "mediaDynamicRange"
        static let viewerMediaDynamicRange = "viewerMediaDynamicRange"
    }
}

/// 端末に1つの設定の保存先。プリセットと、プリセットに含めない値を持つ。
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keepsComposeBarOpenByDefault: Bool

    /// プリセット。読んでも購読にならない。値は`AppSettings`から読み、プリセットの一覧を出す画面は`observedLibrary`を読む。
    /// 1つのプロパティとして購読させると、どの値を変えても、すべての値の購読が反応するため（翻訳の言語の購読が、アクセントカラーを変えただけで翻訳をやり直すなど）。
    @ObservationIgnored public private(set) var library: PresetLibrary {
        didSet {
            appearanceCache = [:]
            for entry in reads.values { entry.value = nil }
            defaults.set(library.storedData, forKey: Keys.presets)
            notifyChanges(from: oldValue)
        }
    }

    /// プリセットを購読して読む。プリセットのどれかが変わると届く。
    public var observedLibrary: PresetLibrary {
        _ = anyChange.revision
        return library
    }

    /// 読むプリセットと値のキーごとの購読。読まれたものだけ作る。
    /// プリセットごとに分けるのは、使っていないプリセットを直しても、同じキーをほかのプリセットで読む画面に届かないようにするため。
    /// 読むプリセットごとに1つにするのは、行を描くたびに数十の値を読むので、読むたびに親をたどって購読を重ねると重いため。親の値が変わったときは、`notifyChanges`が子の購読にも知らせる。
    @ObservationIgnored private var keyChanges: [ValueKey: ChangeSignal] = [:]

    /// 読むプリセットと値のキーごとの、親までたどって解決した値と、その購読。値を持たないキーはnilを覚える。値はプリセットが変わるまで覚える。
    /// 行を描くたびに数十の値を読むので、購読と値を1回で引けるよう、1つの辞書に持つ。
    @ObservationIgnored private var reads: [ValueKey: ReadEntry] = [:]

    private final class ReadEntry {
        let signal: ChangeSignal
        var value: PresetValue??

        init(signal: ChangeSignal) {
            self.signal = signal
        }
    }

    private struct ValueKey: Hashable {
        let preset: PresetID
        let key: String
    }

    /// 「投稿の見た目」の選択肢を、まとめて購読するためのキー。選択肢は行を描くたびにすべて読むので、選択肢ごとに購読しない。
    private static let appearanceChoicesKey = "appearanceChoice"
    /// アプリとアカウントが使うプリセットの選び直し。
    private let selectionChange = ChangeSignal()
    private let anyChange = ChangeSignal()

    /// プリセットごとの、解決した「投稿の見た目」の選択肢。行を描くたびに読むので、プリセットが変わるまで覚える。
    @ObservationIgnored private var appearanceCache: [PresetID: AppearanceChoices] = [:]

    var autoTranslationExcludedHandles: [String] {
        didSet { defaults.set(autoTranslationExcludedHandles, forKey: Keys.autoTranslationExcludedHandles) }
    }

    var autoTranslationLanguages: [String] {
        didSet { defaults.set(autoTranslationLanguages, forKey: Keys.autoTranslationLanguages) }
    }

    var autoTranslationStrategy: TranslationStrategy {
        didSet { defaults.set(autoTranslationStrategy.rawValue, forKey: Keys.autoTranslationStrategy) }
    }

    var autoTranslationModelRevision = 0

    var profilePostsFilter: ProfilePostsFilter {
        didSet {
            defaults.set(profilePostsFilter.showsReplies, forKey: Keys.profileShowsReplies)
            defaults.set(profilePostsFilter.showsBoosts, forKey: Keys.profileShowsBoosts)
        }
    }

    var emojiSkinTone: EmojiSkinTone {
        didSet { defaults.set(emojiSkinTone.rawValue, forKey: Keys.emojiSkinTone) }
    }

    var showsTabMenuCustomize: Bool {
        didSet { defaults.set(showsTabMenuCustomize, forKey: Keys.showsTabMenuCustomize) }
    }

    /// ログアウトで消せるよう、アカウントごとのキー（`AccountScopedDefaults`）に1つずつ保存する。
    private(set) var tabLayouts: [String: MenuLayout<TabItem>]

    /// アカウントごとの、切り替えタブで最後に開いた項目。開くたびに書くので、ほかの設定と違って変更を購読させない。
    @ObservationIgnored private(set) var switchTabItems: [String: TabItem]

    /// アカウントごとの、最後に見ていたタブの項目。切り替えタブの中なら、開いていた項目。起動したときに、この項目を開く。タブを移るたびに書くので、変更を購読させない。
    @ObservationIgnored private(set) var shownTabItems: [String: TabItem]

    /// アカウントごとに覚えた、サーバーの「アニメーションGIFを自動再生する」。キーはアカウントのハンドル。
    /// 起動のたびに既定から始めて、読めたところで動き出さないよう、読めた値を覚えておき、表示を始めるときに使う。
    private(set) var serverAnimationAutoplays: [String: Bool]

    /// アプリの設定（`AppDependencies.settings`）が読む、最後に表示を始めたアカウントのサーバーの値。
    private(set) var lastServerAutoplaysAnimations = false
    @ObservationIgnored private var animationAccount: String?

    public init(defaults: UserDefaults, keepsComposeBarOpenByDefault: Bool = false) {
        self.defaults = defaults
        self.keepsComposeBarOpenByDefault = keepsComposeBarOpenByDefault
        library = PresetLibrary(stored: defaults.data(forKey: Keys.presets))
        autoTranslationExcludedHandles = defaults.stringArray(forKey: Keys.autoTranslationExcludedHandles) ?? []
        autoTranslationLanguages = defaults.stringArray(forKey: Keys.autoTranslationLanguages) ?? []
        // 読めない値（名前を変えた方式など）は、持っていないときと同じく既定値にする。
        autoTranslationStrategy = defaults.string(forKey: Keys.autoTranslationStrategy).flatMap(TranslationStrategy.init(rawValue:)) ?? .lowLatency
        profilePostsFilter = ProfilePostsFilter(
            showsReplies: defaults.object(forKey: Keys.profileShowsReplies) as? Bool ?? ProfilePostsFilter.standard.showsReplies,
            showsBoosts: defaults.object(forKey: Keys.profileShowsBoosts) as? Bool ?? ProfilePostsFilter.standard.showsBoosts
        )
        emojiSkinTone = (defaults.object(forKey: Keys.emojiSkinTone) as? Int).flatMap(EmojiSkinTone.init(rawValue:)) ?? .none
        showsTabMenuCustomize = defaults.object(forKey: Keys.showsTabMenuCustomize) as? Bool ?? true
        tabLayouts = AccountScopedDefaults.accountValues(named: Keys.tabLayout, in: defaults).compactMapValues { ($0 as? [String]).map(MenuLayout.init(tokens:)) }
        switchTabItems = AccountScopedDefaults.accountValues(named: Keys.switchTabItem, in: defaults).compactMapValues { ($0 as? String).flatMap(TabItem.init(rawValue:)) }
        shownTabItems = AccountScopedDefaults.accountValues(named: Keys.shownTabItem, in: defaults).compactMapValues { ($0 as? String).flatMap(TabItem.init(rawValue:)) }
        serverAnimationAutoplays = AccountScopedDefaults.accountValues(named: Keys.serverAutoplaysAnimations, in: defaults).compactMapValues { $0 as? Bool }
    }

    /// プリセットを変える。変えられなかったとき（消えたプリセットを指したなど）は、何も変えない。
    public func updateLibrary(_ change: (inout PresetLibrary) throws(PresetError) -> Void) {
        var updated = library
        do {
            try change(&updated)
        } catch {
            return
        }
        guard updated != library else { return }
        library = updated
    }

    /// プリセットを変え、変えられなかった理由を返す。ショートカットのように、失敗を使う人へ返す操作で使う。
    public func tryUpdateLibrary(_ change: (inout PresetLibrary) throws(PresetError) -> Void) throws(PresetError) {
        var updated = library
        try change(&updated)
        guard updated != library else { return }
        library = updated
    }

    /// アカウントに割り当てたプリセットが使う「絵文字」の種類のうち、アプリのプリセットと違うもの。
    /// 絵文字ピッカーのために、アプリのプリセットの絵に加えて、端末に置く画像を先に作る絵（docs/preset.md）。
    public var accountEmojiStyles: Set<EmojiStyle> {
        let library = observedLibrary
        let appStyle = resolvedAppearance(in: library.appPreset).emojiStyle
        return Set(library.accountPresets.values.map { resolvedAppearance(in: $0).emojiStyle }).subtracting([appStyle])
    }

    /// どれかのプリセット（組み込みのプリセットを含む）が使う「絵文字」の種類。プリセットのどれかが変わると購読に届く。
    /// 絵文字ピッカーのために端末に置いた画像のうち、どのプリセットでも使わない種類のものだけを消すのに使う。
    public var emojiStylesInPresets: Set<EmojiStyle> {
        let library = observedLibrary
        let ids = BuiltInPreset.allCases.map(PresetID.builtIn) + library.userPresets.map { PresetID.user($0.id) }
        return Set(ids.map { resolvedAppearance(in: $0).emojiStyle })
    }

    /// ショートカットから、アプリのプリセットを選ぶか、アカウントにプリセットを割り当てる。アカウントに`nil`を渡すと、割り当てを外す。
    /// 消えたプリセットやログアウトしたアカウントを指したら、何も変えずに失敗する（docs/preset.md）。
    /// - Parameter signedInAccounts: ログインしているアカウントのハンドル。
    public func applyShortcut(selecting id: PresetID?, for scope: PresetScope, signedInAccounts: [String]) throws(PresetError) {
        if case .account(let handle) = scope, !signedInAccounts.contains(handle) {
            throw .accountNotFound
        }
        try tryUpdateLibrary { library throws(PresetError) in
            switch (id, scope) {
            case (let id?, _): try library.select(id, for: scope)
            case (nil, .account(let handle)): library.unassign(account: handle)
            case (nil, .app): throw .presetNotFound
            }
        }
    }

    func resolvedAppearance(in preset: PresetID) -> AppearanceChoices {
        track(Self.appearanceChoicesKey, in: preset)
        if let cached = appearanceCache[preset] { return cached }
        var values: [String: PresetValue] = [:]
        for field in AppearanceStorage.fieldNames {
            if let value = library.value(forKey: AppearanceStorage.key(field), in: preset) {
                values[field] = value
            }
        }
        let resolved = AppearanceStorage.choices(from: values)
        appearanceCache[preset] = resolved
        return resolved
    }

    /// `preset`で読む`key`の値の変化を購読する。値を受け継ぐ先祖のプリセットの変化も、`notifyChanges`がこの購読に知らせる。
    func track(_ key: String, in preset: PresetID) {
        _ = signal(for: ValueKey(preset: preset, key: key)).revision
    }

    /// `preset`で読む`key`の値を、変化を購読して読む。親までたどった結果を、プリセットが変わるまで覚える。
    func read(_ key: String, in preset: PresetID) -> PresetValue? {
        let valueKey = ValueKey(preset: preset, key: key)
        let entry = reads[valueKey] ?? {
            let created = ReadEntry(signal: signal(for: valueKey))
            reads[valueKey] = created
            return created
        }()
        _ = entry.signal.revision
        if let cached = entry.value { return cached }
        let resolved = library.value(forKey: key, in: preset)
        entry.value = .some(resolved)
        return resolved
    }

    private func signal(for valueKey: ValueKey) -> ChangeSignal {
        if let signal = keyChanges[valueKey] { return signal }
        let created = ChangeSignal()
        keyChanges[valueKey] = created
        return created
    }

    /// アプリとアカウントが使うプリセットの選び直しを購読する。
    func trackSelection() {
        _ = selectionChange.revision
    }

    /// 前のプリセットと比べ、変わったものの購読だけに知らせる。プリセットを作っただけでは、ほかのプリセットの値は変わらないので知らせない。
    private func notifyChanges(from old: PresetLibrary) {
        anyChange.revision += 1
        if old.appPreset != library.appPreset || old.accountPresets != library.accountPresets {
            selectionChange.revision += 1
        }
        let oldPresets = Dictionary(uniqueKeysWithValues: old.userPresets.map { ($0.id, $0) })
        let newPresets = Dictionary(uniqueKeysWithValues: library.userPresets.map { ($0.id, $0) })
        let structureChanged = oldPresets.contains { id, preset in newPresets[id]?.parent != preset.parent }
        // 親の付け替えと削除では、値をたどる道が変わり、どの値も変わりうるので、すべての購読に知らせる。
        // 値を読むたびに付け替えの購読も重ねると、行を描くたびに数十の値を読むので重いため、読む側では購読しない。
        if structureChanged {
            selectionChange.revision += 1
            for signal in keyChanges.values { signal.revision += 1 }
            return
        }
        var changed: Set<ValueKey> = []
        for (id, preset) in newPresets {
            let before = oldPresets[id]?.values ?? [:]
            for key in Set(before.keys).union(preset.values.keys) where before[key] != preset.values[key] {
                changed.insert(ValueKey(preset: .user(id), key: key))
                if key.hasPrefix(Self.appearanceChoicesKey + ".") {
                    changed.insert(ValueKey(preset: .user(id), key: Self.appearanceChoicesKey))
                }
            }
        }
        guard !changed.isEmpty else { return }
        // 読むプリセットか、その先祖のプリセットの値が変わった購読に知らせる。
        for (valueKey, signal) in keyChanges {
            let chain = [valueKey.preset] + library.ancestors(of: valueKey.preset)
            if chain.contains(where: { changed.contains(ValueKey(preset: $0, key: valueKey.key)) }) {
                signal.revision += 1
            }
        }
    }

    func setTabLayout(_ layout: MenuLayout<TabItem>, for account: String) {
        tabLayouts[account] = layout
        defaults.set(layout.tokens, forKey: AccountScopedDefaults.key(Keys.tabLayout, account: account))
    }

    func setSwitchTabItem(_ item: TabItem, for account: String) {
        guard switchTabItems[account] != item else { return }
        switchTabItems[account] = item
        defaults.set(item.rawValue, forKey: AccountScopedDefaults.key(Keys.switchTabItem, account: account))
    }

    func setShownTabItem(_ item: TabItem, for account: String) {
        guard shownTabItems[account] != item else { return }
        shownTabItems[account] = item
        defaults.set(item.rawValue, forKey: AccountScopedDefaults.key(Keys.shownTabItem, account: account))
    }

    func followServerAnimations(of account: String) {
        animationAccount = account
        let autoplays = serverAnimationAutoplays[account] ?? false
        if lastServerAutoplaysAnimations != autoplays {
            lastServerAutoplaysAnimations = autoplays
        }
    }

    func rememberServerAnimations(_ autoplays: Bool, of account: String) {
        if serverAnimationAutoplays[account] != autoplays {
            serverAnimationAutoplays[account] = autoplays
            defaults.set(autoplays, forKey: AccountScopedDefaults.key(Keys.serverAutoplaysAnimations, account: account))
        }
        if animationAccount == account, lastServerAutoplaysAnimations != autoplays {
            lastServerAutoplaysAnimations = autoplays
        }
    }

    func forgetAccount(_ account: String) {
        tabLayouts[account] = nil
        switchTabItems[account] = nil
        shownTabItems[account] = nil
        serverAnimationAutoplays[account] = nil
        if animationAccount == account {
            lastServerAutoplaysAnimations = false
        }
        updateLibrary { $0.forgetAccount(account) }
    }

    private enum Keys {
        static let presets = "settings.presets"
        static let autoTranslationExcludedHandles = "settings.autoTranslationExcludedHandles"
        static let autoTranslationLanguages = "settings.autoTranslationLanguages"
        static let autoTranslationStrategy = "settings.autoTranslationStrategy"
        static let profileShowsReplies = "settings.profileShowsReplies"
        static let profileShowsBoosts = "settings.profileShowsBoosts"
        static let emojiSkinTone = "settings.emojiSkinTone"
        static let showsTabMenuCustomize = "settings.showsTabMenuCustomize"
        /// `AccountScopedDefaults`で、アカウントごとのキーにする名前。
        static let tabLayout = "tabLayout"
        static let switchTabItem = "switchTabItem"
        static let shownTabItem = "shownTabItem"
        static let serverAutoplaysAnimations = "serverAutoplaysAnimations"
    }
}

/// 購読させるための印。値が変わったことだけを知らせる。
@MainActor
@Observable
final class ChangeSignal {
    var revision = 0
}

/// 「投稿の見た目」の選択肢を、選択肢ごとのプリセットの値に分けて持つ形。
enum AppearanceStorage {
    static let revealsAllPartsInThread = "revealsAllPartsInThread"

    /// 選択肢の名前。既定ではnilの項目は既定の値のJSONに出ないので、プロパティの名前で決める。
    static let fieldNames: [String] = Mirror(reflecting: AppearanceChoices()).children.compactMap(\.label)

    static func key(_ field: String) -> String {
        "appearanceChoice.\(field)"
    }

    /// 選択肢ごとの値。nilの項目は`.null`にする。
    static func fields(of choices: AppearanceChoices) -> [String: PresetValue] {
        let encoded = (try? JSONSerialization.jsonObject(with: choices.storedData)) as? [String: Any] ?? [:]
        var fields: [String: PresetValue] = [:]
        for name in fieldNames {
            fields[name] = encoded[name].flatMap(presetValue) ?? .null
        }
        return fields
    }

    /// 持っていない項目は既定値に、読めない値の項目も既定値にする（`AppearanceChoices(stored:)`）。
    static func choices(from values: [String: PresetValue]) -> AppearanceChoices {
        let object = values.mapValues(jsonValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return AppearanceChoices() }
        return AppearanceChoices(stored: data)
    }

    private static func presetValue(_ value: Any) -> PresetValue? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): .bool(number.boolValue)
        case let number as NSNumber: .number(number.doubleValue)
        case let text as String: .text(text)
        case is NSNull: .null
        default: nil
        }
    }

    private static func jsonValue(_ value: PresetValue) -> Any {
        switch value {
        case .bool(let bool): bool
        case .number(let number): number
        case .text(let text): text
        case .list(let list): list
        case .null: NSNull()
        }
    }
}

extension AppearanceChoice {
    /// `AppearanceChoices`の中の、この選択肢のプロパティの名前。
    var field: String {
        switch self {
        case .nameStyle: "statusNameStyle"
        case .timeStyle: "statusTimeStyle"
        default: "\(self)"
        }
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
    static let drawsReactionGlowInHDR = true
    static let reactionGlowIcons: ReactionGlowIcons = .none
    static let reactionGlowFillsWidthWhenAlone = false
    static let reactionGlowLightFavouriteColor: ReactionGlowLightFavouriteColor = .orange
}
