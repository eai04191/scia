import Foundation
import Testing
@testable import SciaCore

@MainActor
struct AppSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
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

    /// 一覧ではたくさんのメディアが文字と並ぶのでSDRに収め、ビューアでは眩しすぎないよう抑えたHDRで描くのを既定にする。
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

    /// HDRで描ける画面では、お気に入りとブーストの光を既定で白より明るく光らせる。白い背景の上では、HDRでないと光って見えないため。
    @Test func drawsReactionGlowInHDRByDefault() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.drawsReactionGlowInHDR)
    }

    @Test func persistsDrawsReactionGlowInHDR() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).drawsReactionGlowInHDR = false
        #expect(!AppSettings(defaults: defaults).drawsReactionGlowInHDR)
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

    @Test func statusDisplayDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.statusNameStyle == .nameAndAcct)
        #expect(settings.statusTimeStyle == .relative)
        #expect(settings.avatarShape == .roundedSquare)
        #expect(settings.linkCardThumbnailSide == .left)
        #expect(settings.glyphLanguage == .automatic)
        #expect(settings.emojiStyle == .system)
        // 一覧でたくさん動くと読みにくいため、既定では止める。
        #expect(!settings.animatesAvatars)
        #expect(!settings.animatesCustomEmojis)
    }

    @Test func persistsStatusDisplay() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.statusNameStyle = .acctOnly
        settings.statusTimeStyle = .absolute
        settings.avatarShape = .circle
        settings.linkCardThumbnailSide = .right
        settings.glyphLanguage = .traditionalChinese
        settings.emojiStyle = .twemoji
        settings.animatesAvatars = true
        settings.animatesCustomEmojis = true

        let restored = AppSettings(defaults: defaults)
        #expect(restored.statusNameStyle == .acctOnly)
        #expect(restored.statusTimeStyle == .absolute)
        #expect(restored.avatarShape == .circle)
        #expect(restored.linkCardThumbnailSide == .right)
        #expect(restored.glyphLanguage == .traditionalChinese)
        #expect(restored.emojiStyle == .twemoji)
        #expect(restored.animatesAvatars)
        #expect(restored.animatesCustomEmojis)
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

    @Test func persistsProfilePostsFilter() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).profilePostsFilter == .standard)

        AppSettings(defaults: defaults).profilePostsFilter = ProfilePostsFilter(showsReplies: true, showsBoosts: false)

        #expect(AppSettings(defaults: defaults).profilePostsFilter == ProfilePostsFilter(showsReplies: true, showsBoosts: false))
    }

    /// アプリを離れて既定のブラウザで開くのが一般に好まれるため、既定は外で開く。
    @Test func opensLinksExternallyByDefault() throws {
        #expect(AppSettings(defaults: try makeDefaults()).linkBrowser == .external)
    }

    @Test func persistsLinkBrowser() throws {
        let defaults = try makeDefaults()
        AppSettings(defaults: defaults).linkBrowser = .inApp
        #expect(AppSettings(defaults: defaults).linkBrowser == .inApp)
    }

    /// 既定は、設定を足す前と同じく公開範囲を送らず、アカウントの既定に任せる。
    @Test func reblogsWithAccountDefaultUntilChosen() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).reblogVisibility == .accountDefault)

        AppSettings(defaults: defaults).reblogVisibility = .private
        #expect(AppSettings(defaults: defaults).reblogVisibility == .private)
    }
}
