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

    @Test func statusDisplayDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        #expect(settings.statusNameStyle == .nameAndAcct)
        #expect(settings.statusTimeStyle == .relative)
        #expect(settings.avatarShape == .roundedSquare)
        #expect(settings.linkCardThumbnailSide == .left)
        #expect(settings.glyphLanguage == .automatic)
        // 一覧でたくさん動くと読みにくいため、既定では止める。
        #expect(!settings.animatesAvatars)
    }

    @Test func persistsStatusDisplay() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.statusNameStyle = .acctOnly
        settings.statusTimeStyle = .absolute
        settings.avatarShape = .circle
        settings.linkCardThumbnailSide = .right
        settings.glyphLanguage = .traditionalChinese
        settings.animatesAvatars = true

        let restored = AppSettings(defaults: defaults)
        #expect(restored.statusNameStyle == .acctOnly)
        #expect(restored.statusTimeStyle == .absolute)
        #expect(restored.avatarShape == .circle)
        #expect(restored.linkCardThumbnailSide == .right)
        #expect(restored.glyphLanguage == .traditionalChinese)
        #expect(restored.animatesAvatars)
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
}
