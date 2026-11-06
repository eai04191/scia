import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct AppSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = TestScratch.defaults("AppSettingsTests")
        return defaults
    }

    /// 通信量より見た目を優先し、モバイル通信でも元の画像を読むのを既定にする。
    @Test func usesOriginalThumbnailsOnExpensiveNetworkByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.usesOriginalThumbnailsOnExpensiveNetwork)
    }

    /// 標準では、iPhoneの標準の写真と動画より大きなものだけを縮める。
    @Test func uploadSizeDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.imageUploadSize == .long4096)
        #expect(settings.videoUploadSize == .p1080)
    }

    @Test func persistsUploadSizes() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.imageUploadSize = .original
        settings.videoUploadSize = .p720
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.imageUploadSize == .original)
        #expect(relaunched.videoUploadSize == .p720)
    }

    /// タイムラインではたくさんのメディアが文字と並ぶのでSDRに収め、ビューアでは眩しすぎないよう抑えたHDRで描くのを既定にする。
    @Test func mediaDynamicRangeDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.mediaDynamicRange == .standard)
        #expect(settings.viewerMediaDynamicRange == .constrainedHigh)
    }

    @Test func persistsMediaDynamicRanges() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.mediaDynamicRange = .high
        settings.viewerMediaDynamicRange = .standard
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.mediaDynamicRange == .high)
        #expect(relaunched.viewerMediaDynamicRange == .standard)
    }

    @Test func persistsChangesAcrossLaunches() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).usesOriginalThumbnailsOnExpensiveNetwork = false
        #expect(!AppSettings(defaults: defaults).usesOriginalThumbnailsOnExpensiveNetwork)
    }

    /// 中身のない代替テキストにALTが付くと、説明があるという目印として当てにならないため、既定で除く。
    @Test func ignoresUselessAltTextByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.ignoresUselessAltText)
    }

    @Test func persistsIgnoresUselessAltText() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).ignoresUselessAltText = false
        #expect(!AppSettings(defaults: defaults).ignoresUselessAltText)
    }

    /// 表示しただけでSciaと関係のないfxtwitterとXに通信するので、使う人がオンにするまで展開しない。
    @Test func doesNotExpandXPostsByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(!settings.expandsXPosts)
    }

    @Test func persistsExpandsXPosts() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).expandsXPosts = true
        #expect(AppSettings(defaults: defaults).expandsXPosts)
    }

    /// HDRで描ける画面では、お気に入りとブーストの光を既定で白より明るく光らせる。白い背景の上では、HDRでないと光って見えないため。
    @Test func drawsReactionGlowInHDRByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.appearance.drawsReactionGlowInHDR)
    }

    @Test func persistsDrawsReactionGlowInHDR() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).appearance.drawsReactionGlowInHDR = false
        #expect(!AppSettings(defaults: defaults).appearance.drawsReactionGlowInHDR)
    }

    /// 届いた通知に気づけるよう、ステータスバーの通知は既定で流す。
    @Test func showsStatusBarTickerByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.showsStatusBarTicker)
    }

    @Test func persistsShowsStatusBarTicker() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).showsStatusBarTicker = false
        #expect(!AppSettings(defaults: defaults).showsStatusBarTicker)
    }

    /// 投稿欄がいつも見えていることで、タイムラインを見たまま書き始められるため、既定では隠さない。
    @Test func showsEmptyComposeBarByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(!settings.hidesEmptyComposeBar)
    }

    @Test func persistsHidesEmptyComposeBar() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).hidesEmptyComposeBar = true
        #expect(AppSettings(defaults: defaults).hidesEmptyComposeBar)
    }

    /// 畳んでもタイムラインを広く使えるので、既定では畳む。
    @Test func foldsComposeBarByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(!settings.keepsComposeBarOpen)
    }

    /// Macのように既定で畳まない端末でも、使う人がオフにしたらオフのままにする。
    @Test func keepsComposeBarOpenFollowsDeviceDefaultUntilChosen() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults, keepsComposeBarOpenByDefault: true).keepsComposeBarOpen)
        AppSettings(defaults: defaults, keepsComposeBarOpenByDefault: true).keepsComposeBarOpen = false
        #expect(!AppSettings(defaults: defaults, keepsComposeBarOpenByDefault: true).keepsComposeBarOpen)
    }

    /// 設定の画面の1つの選択が、2つの保存値のどの組み合わせになるか。
    @Test(arguments: [(ComposeBarIdle.hidden, true, false), (.collapsed, false, false), (.open, false, true)])
    func composeBarIdleSetsBothFlags(idle: ComposeBarIdle, hides: Bool, keepsOpen: Bool) throws {
        let settings = AppSettings(defaults: try makeDefaults(), keepsComposeBarOpenByDefault: !keepsOpen)
        settings.hidesEmptyComposeBar = !hides
        settings.composeBarIdle = idle
        #expect(settings.hidesEmptyComposeBar == hides)
        #expect(settings.keepsComposeBarOpen == keepsOpen)
        #expect(settings.composeBarIdle == idle)
    }

    /// 前に両方をオンにしていたら、隠すほうとして読む。
    @Test func readsHiddenWhenBothFlagsAreOn() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.hidesEmptyComposeBar = true
        settings.keepsComposeBarOpen = true
        #expect(settings.composeBarIdle == .hidden)
    }

    @Test func persistsKeepsComposeBarOpen() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).keepsComposeBarOpen = true
        #expect(AppSettings(defaults: defaults).keepsComposeBarOpen)
    }

    @Test func statusDisplayDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.appearance.statusNameStyle == .nameAndAcct)
        #expect(settings.appearance.statusTimeStyle == .relative)
        #expect(settings.appearance.avatarShape == .roundedSquare)
        #expect(settings.appearance.linkCardThumbnailSide == .left)
        #expect(settings.appearance.glyphLanguage == .automatic)
        #expect(settings.appearance.emojiStyle == .system)
        // 選ぶまではサーバーの値に従い、サーバーの値が分からないうちは、Mastodonの既定と同じく止める。
        #expect(settings.appearance.animatesAvatars == nil)
        #expect(settings.appearance.animatesCustomEmojis == nil)
        #expect(!settings.animatesAvatars)
        #expect(!settings.animatesCustomEmojis)
    }

    /// アイコンとカスタム絵文字のアニメーションは、選ぶまでは表示しているアカウントのサーバーの値に従い、選んだらその値を使う。
    @Test func animationsFollowServerUntilChosen() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.followServerAnimations(of: "alice@example.social")
        settings.rememberServerAnimations(true, of: "alice@example.social")
        #expect(settings.animatesAvatars)
        #expect(settings.animatesCustomEmojis)

        settings.animatesCustomEmojis = false
        #expect(settings.appearance.animatesCustomEmojis == false)
        #expect(!settings.animatesCustomEmojis)
        #expect(settings.animatesAvatars)

        // 既定に戻すと、選んだ値を忘れてサーバーの値に戻る。
        settings.resetAppearance()
        #expect(settings.animatesCustomEmojis)
    }

    /// サーバーの値はアカウントごとに覚え、次に表示を始めたときは読み直す前から覚えた値で描く。
    /// 表示していないアカウントの値を読んでも、表示しているアカウントの値は変えない。
    @Test func remembersServerAnimationsPerAccount() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.followServerAnimations(of: "alice@example.social")
        settings.rememberServerAnimations(true, of: "alice@example.social")
        settings.rememberServerAnimations(false, of: "bob@example.social")
        #expect(settings.animatesCustomEmojis)

        settings.followServerAnimations(of: "bob@example.social")
        #expect(!settings.animatesCustomEmojis)

        let relaunched = AppSettings(defaults: defaults)
        #expect(!relaunched.animatesCustomEmojis)
        relaunched.followServerAnimations(of: "alice@example.social")
        #expect(relaunched.animatesCustomEmojis)
        relaunched.followServerAnimations(of: "carol@example.social")
        #expect(!relaunched.animatesCustomEmojis)
    }

    @Test func persistsStatusDisplay() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.appearance.statusNameStyle = .acctOnly
        settings.appearance.statusTimeStyle = .absolute
        settings.appearance.avatarShape = .circle
        settings.appearance.linkCardThumbnailSide = .right
        settings.appearance.glyphLanguage = .traditionalChinese
        settings.appearance.emojiStyle = .twemoji
        settings.appearance.animatesAvatars = true
        settings.appearance.animatesCustomEmojis = false

        let restored = AppSettings(defaults: defaults)
        #expect(restored.appearance.statusNameStyle == .acctOnly)
        #expect(restored.appearance.statusTimeStyle == .absolute)
        #expect(restored.appearance.avatarShape == .circle)
        #expect(restored.appearance.linkCardThumbnailSide == .right)
        #expect(restored.appearance.glyphLanguage == .traditionalChinese)
        #expect(restored.appearance.emojiStyle == .twemoji)
        #expect(restored.appearance.animatesAvatars == true)
        #expect(restored.appearance.animatesCustomEmojis == false)
    }

    /// 新着の挿入は、既定では端末の「視差効果を減らす」に従い、選び直した値は起動し直しても残る。
    @Test func insertionMotionFollowsSystemByDefaultAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.insertionMotion == .followsSystem)

        settings.insertionMotion = .instant

        #expect(AppSettings(defaults: defaults).insertionMotion == .instant)
    }

    @Test(arguments: [
        (InsertionMotion.followsSystem, false, true),
        (.followsSystem, true, false),
        (.animated, true, true),
        (.instant, false, false),
    ])
    func insertionMotionAnimates(_ motion: InsertionMotion, reducesMotion: Bool, expected: Bool) {
        #expect(motion.animates(reducesMotion: reducesMotion) == expected)
    }

    /// アクセントカラーは、既定ではシステムと同じ青で、選び直した値は起動し直しても残る。
    @Test func accentColorIsBlueByDefaultAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.accentColor == .blue)

        settings.accentColor = .orange

        #expect(AppSettings(defaults: defaults).accentColor == .orange)
    }

    /// 本文の文字や控えめな文字と色で見分けられないアクセントカラーでだけ、リンクに下線を引く。
    @Test func underlinesLinksOnlyForColorsIndistinguishableFromText() {
        #expect(AccentColorChoice.allCases.filter(\.underlinesLinks) == [.gray, .monochrome])
    }

    @Test func persistsProfilePostsFilter() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).profilePostsFilter == .standard)

        AppSettings(defaults: defaults).profilePostsFilter = ProfilePostsFilter(showsReplies: true, showsBoosts: false)

        #expect(AppSettings(defaults: defaults).profilePostsFilter == ProfilePostsFilter(showsReplies: true, showsBoosts: false))
    }

    /// 読んでいる間もタイムラインが流れ続けるよう、既定はアプリ内のSafariで開く。
    @Test func opensLinksInAppByDefault() throws {
        #expect(AppSettings(defaults: try makeDefaults()).linkBrowser == .inApp)
    }

    @Test func persistsLinkBrowser() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).linkBrowser = .external
        #expect(AppSettings(defaults: defaults).linkBrowser == .external)
    }

    @Test func inAppBrowserHeightIsStandardByDefaultAndPersists() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).inAppBrowserHeight == .standard)
        AppSettings(defaults: defaults).inAppBrowserHeight = InAppBrowserHeight(spaceAbove: 132)
        #expect(AppSettings(defaults: defaults).inAppBrowserHeight == InAppBrowserHeight(spaceAbove: 132))
    }

    /// 数でない値が保存されていても、刻みに寄せられないので、保存していないときと同じく標準にする。
    @Test func inAppBrowserHeightIgnoresNonFiniteStoredValue() throws {
        let defaults = try makeDefaults()
        defaults.set(Double.nan, forKey: "settings.inAppBrowserSpaceAbove")
        #expect(AppSettings(defaults: defaults).inAppBrowserHeight == .standard)
    }

    @Test func opensInAppBrowserFullScreenIsOffByDefaultAndPersists() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).opensInAppBrowserFullScreen == false)
        AppSettings(defaults: defaults).opensInAppBrowserFullScreen = true
        #expect(AppSettings(defaults: defaults).opensInAppBrowserFullScreen)
    }

    /// 既定は、設定を足す前と同じく公開範囲を送らず、アカウントの既定に任せる。
    @Test func reblogsWithAccountDefaultUntilChosen() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).reblogVisibility == .accountDefault)

        AppSettings(defaults: defaults).reblogVisibility = .private
        #expect(AppSettings(defaults: defaults).reblogVisibility == .private)
    }

    /// 見た目の値は、変えるまで既定値を返し、変えた値は起動し直しても残る。範囲外は範囲に収める。
    @Test func persistsAppearanceValues() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let item = AppearanceCatalog.nameBodySpacing
        #expect(settings.value(of: item) == item.defaultValue)
        #expect(!settings.isModified(item))
        settings.setValue(8, for: item)
        settings.setValue(1_000, for: AppearanceCatalog.bodyText)
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.value(of: item) == 8)
        #expect(relaunched.isModified(item))
        #expect(relaunched.value(of: AppearanceCatalog.bodyText) == AppearanceCatalog.bodyText.range.upperBound)
    }

    /// ＋−で刻みずつ足し引きして既定値に戻したら、変えていない扱いにする。0.1のような刻みは2進数で表せず、足すたびに誤差が溜まるため。
    /// 打って入れた、刻みの倍数でない値はそのまま残す。
    @Test func steppingBackToDefaultIsNotModified() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            // 5刻み離れた値から、＋−と同じく1刻みずつ足し引きして既定値まで戻す。
            let below = item.defaultValue - 5 * item.step
            let direction: Double = item.range.contains(below) ? 1 : -1
            var value = item.defaultValue - direction * 5 * item.step
            for _ in 0..<5 { value += direction * item.step }
            settings.setValue(value, for: item)
            #expect(!settings.isModified(item), "\(item.id) \(value)")
        }
        let item = AppearanceCatalog.nameUnicodeEmojiScale
        settings.setValue(1.23, for: item)
        #expect(settings.value(of: item) == 1.23)
    }

    @Test func resetsAppearanceValues() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setValue(8, for: AppearanceCatalog.nameBodySpacing)
        settings.setValue(4, for: AppearanceCatalog.bodyText)
        settings.reset([AppearanceCatalog.nameBodySpacing])
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.value(of: AppearanceCatalog.nameBodySpacing) == AppearanceCatalog.nameBodySpacing.defaultValue)
        #expect(relaunched.value(of: AppearanceCatalog.bodyText) == 4)
    }

    /// 保存のキーが重なると、別の項目の値を読んでしまう。
    @Test func appearanceIDsAreUnique() {
        let ids = (AppearanceCatalog.values + NotificationAppearanceCatalog.values).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// 「通知の見た目」の数値も保存して読み直せ、まとめて既定に戻すと「投稿の見た目」の数値は残る。
    @Test func notificationAppearancePersistsAndResetsAlone() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setValue(12, for: NotificationAppearanceCatalog.quotedPollSpacing)
        settings.setValue(4, for: AppearanceCatalog.bodyText)
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.value(of: NotificationAppearanceCatalog.quotedPollSpacing) == 12)
        #expect(relaunched.isNotificationAppearanceModified)
        relaunched.resetNotificationAppearance()
        #expect(!relaunched.isNotificationAppearanceModified)
        #expect(AppSettings(defaults: defaults).value(of: NotificationAppearanceCatalog.quotedPollSpacing) == NotificationAppearanceCatalog.quotedPollSpacing.defaultValue)
        #expect(AppSettings(defaults: defaults).value(of: AppearanceCatalog.bodyText) == 4)
    }

    /// 名前の上の行は狭いので、ブーストした人は名前だけを既定にする。
    @Test func contextNameStyleDefaultsToNameOnly() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).appearance.contextNameStyle == .nameOnly)
        AppSettings(defaults: defaults).appearance.contextNameStyle = .acctOnly
        #expect(AppSettings(defaults: defaults).appearance.contextNameStyle == .acctOnly)
    }

    /// 数でない値（NaNや無限）は保存しない。行数などを整数に直すところで落ちるため。
    @Test func rejectsNonFiniteAppearanceValues() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        let item = AppearanceCatalog.linkCardDescriptionLines
        settings.setValue(2, for: item)
        settings.setValue(.nan, for: item)
        settings.setValue(.infinity, for: item)
        #expect(settings.value(of: item) == 2)
    }

    /// 「投稿の見た目」をまとめて戻すと、数値だけでなく、名前の表記や出すかどうかのスイッチも既定に戻す。
    @Test func resetAppearanceRestoresChoices() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.isAppearanceModified)
        settings.appearance.showsTime = false
        #expect(settings.isAppearanceModified)
        settings.appearance.statusNameStyle = .acctOnly
        settings.setValue(30, for: AppearanceCatalog.avatarSize)
        settings.resetAppearance()
        #expect(!settings.isAppearanceModified)
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.appearance.showsTime)
        #expect(relaunched.appearance.statusNameStyle == .nameAndAcct)
        #expect(relaunched.value(of: AppearanceCatalog.avatarSize) == AppearanceCatalog.avatarSize.defaultValue)
    }

    /// 保存したあとに選択肢を足しても、保存にない項目だけを既定値にし、保存した項目は残す。
    @Test func appearanceChoicesKeepSavedValuesWhenFieldsAreMissing() throws {
        let data = Data(#"{"showsTime":false}"#.utf8)
        let choices = AppearanceChoices(stored: data)

        #expect(!choices.showsTime)
        #expect(choices.statusNameStyle == AppearanceChoices().statusNameStyle)
    }

    /// 読めない値（名前を変えた選択肢など）がある項目だけを既定値に戻し、ほかの項目は保存した値のまま読む。
    @Test func appearanceChoicesDropOnlyUnreadableFields() throws {
        let data = Data(#"{"showsTime":false,"statusNameStyle":"removedStyle","avatarShape":"circle"}"#.utf8)
        let choices = AppearanceChoices(stored: data)

        #expect(!choices.showsTime)
        #expect(choices.avatarShape == .circle)
        #expect(choices.statusNameStyle == AppearanceChoices().statusNameStyle)
    }

    /// 既定ではnilの項目（選ぶまでサーバーの値に従うアニメーション）も、ほかの項目が読めないときに、保存した値のまま読む。
    @Test func appearanceChoicesKeepOptionalFieldsWhenOtherFieldsAreUnreadable() throws {
        let data = Data(#"{"statusNameStyle":"removedStyle","animatesAvatars":true,"animatesCustomEmojis":false}"#.utf8)
        let choices = AppearanceChoices(stored: data)

        #expect(choices.animatesAvatars == true)
        #expect(choices.animatesCustomEmojis == false)
        #expect(choices.statusNameStyle == AppearanceChoices().statusNameStyle)
    }

    /// 引用とXの投稿の並べ方は、「投稿と同じ」なら投稿の並べ方に従い、ほかは投稿によらずその並べ方にする。重ねた写真の選択肢は、どちらかで重ねるときに効く。
    @Test(arguments: [
        (EmbedMediaArrangement.sameAsPost, MediaArrangement.belowBody, MediaArrangement.belowBody, false),
        (.sameAsPost, .besideBody, .besideBody, true),
        (.besideBody, .belowBody, .besideBody, true),
        (.belowBody, .besideBody, .belowBody, true),
        (.belowBody, .belowBody, .belowBody, false),
    ])
    func embedMediaArrangementResolvesAgainstPost(embed: EmbedMediaArrangement, post: MediaArrangement, resolved: MediaArrangement, stacks: Bool) {
        var choices = AppearanceChoices()
        choices.mediaArrangement = post
        choices.embedMediaArrangement = embed

        #expect(choices.resolvedEmbedMediaArrangement == resolved)
        #expect(choices.stacksMediaBesideBody == stacks)
    }

    /// 保存がないか、JSONとして読めなければ、すべて既定値にする。
    @Test(arguments: [nil, Data("not json".utf8)] as [Data?])
    func appearanceChoicesFallBackToDefaults(data: Data?) {
        #expect(AppearanceChoices(stored: data) == AppearanceChoices())
    }

    /// 「投稿の見た目」に移したお気に入りとブーストの光の選択肢も、まとめて戻す対象にし、起動し直しても残る。
    @Test(arguments: [
        { (settings: AppSettings) in settings.appearance.drawsReactionGlowInHDR = false },
        { (settings: AppSettings) in settings.appearance.reactionGlowIcons = .scattered },
        { (settings: AppSettings) in settings.appearance.reactionGlowFillsWidthWhenAlone = true },
        { (settings: AppSettings) in settings.appearance.reactionGlowLightFavouriteColor = .yellow },
    ] as [@MainActor @Sendable (AppSettings) -> Void])
    func reactionGlowChoicesAreAppearance(change: @MainActor @Sendable (AppSettings) -> Void) throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        change(settings)
        #expect(settings.isAppearanceModified)
        #expect(AppSettings(defaults: defaults).isAppearanceModified)
        settings.resetAppearance()
        #expect(!settings.isAppearanceModified)
        #expect(!AppSettings(defaults: defaults).isAppearanceModified)
    }
}
