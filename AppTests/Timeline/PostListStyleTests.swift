import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿を並べるリストの見た目。タイムラインと予約投稿のタイムラインが使う。
@MainActor
@Suite(.failureState, .scratch)
struct PostListStyleTests {
    /// 投稿の見た目の設定が変わるたびに、描き直しを求める。1回で見張りをやめない。
    @Test func asksForRedrawOnEveryAppearanceChange() async throws {
        let settings = AppSettings.isolated()
        let style = PostListStyle(settings: settings, tuning: TuningStore(defaults: nil), network: AppDependencies.network)
        var count = 0
        style.onRedrawNeeded = { count += 1 }
        style.observeRedrawNeeds()

        settings.appearance.showsSeparators = false
        try await waitUntil { count >= 1 }
        settings.appearance.wrapsBelowAvatar = true
        try await waitUntil { count >= 2 }
    }

    /// 見えていない間と、設定の画面が手前にある間は、描き直しを求めずに溜め、見えたとき、手前でなくなったときに1回だけ求める。
    @Test func holdsRedrawWhileHiddenOrBehindSettings() async throws {
        let settings = AppSettings.isolated()
        let style = PostListStyle(settings: settings, tuning: TuningStore(defaults: nil), network: AppDependencies.network)
        var count = 0
        var isShown = false
        style.onRedrawNeeded = { count += 1 }
        style.isShown = { isShown }
        style.observeRedrawNeeds()

        settings.appearance.showsSeparators = false
        try await waitUntil { style.hasHeldChange }
        #expect(count == 0)
        isShown = true
        style.applyHeldChange()
        #expect(count == 1)
        #expect(!style.hasHeldChange)

        style.holdsChanges = true
        settings.appearance.wrapsBelowAvatar = true
        try await waitUntil { style.hasHeldChange }
        #expect(count == 1)
        style.holdsChanges = false
        #expect(count == 2)
        #expect(!style.hasHeldChange)
    }

    /// 下の行と線でつながっている行は、下の区切り線を出さない。線を引き始める位置を渡した行は、そこから引く。
    @Test func exceptionsOverridePostDefaults() {
        let settings = AppSettings.isolated()
        let style = PostListStyle(settings: settings, tuning: TuningStore(defaults: nil), network: AppDependencies.network)
        let base = UIListSeparatorConfiguration(listAppearance: .plain)

        let joined = style.separator(base, isFirst: false, isLast: false, joinsNext: true)
        let custom = style.separator(base, isFirst: false, isLast: false, leading: 7)

        #expect(joined.bottomSeparatorVisibility == .hidden)
        #expect(joined.topSeparatorVisibility != .hidden)
        #expect(custom.bottomSeparatorInsets.leading == 7)
        #expect(custom.topSeparatorInsets.leading == 7)
    }
}
