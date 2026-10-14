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
}
