import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// 設定の画面で、今の設定で使わない行を出さないこと。
@Suite(.scratch)
@MainActor
struct SettingsItemVisibilityTests {
    /// シートの高さは、リンクをアプリ内のSafariのシートで開くときだけ使うので、そのときだけ出す。
    @Test(arguments: [(LinkBrowser.external, false), (.inApp, true), (.inAppFullScreen, false)])
    func showsSheetHeightOnlyForSheet(browser: LinkBrowser, shown: Bool) {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsItemVisibilityTests"))
        settings.linkBrowser = browser
        #expect(SettingsItem.inAppBrowserHeight.isShown(in: settings) == shown)
        #expect(SettingsItem.linkBrowser.isShown(in: settings))
    }
}
