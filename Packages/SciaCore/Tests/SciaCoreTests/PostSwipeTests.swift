import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct PostSwipeTests {
    /// 既定では何も割り当てない（docs/object-actions.mdの「投稿のスワイプ」）。
    @Test func defaultLayoutShowsNothing() {
        #expect(PostSwipeItem.defaultLayout.swipeItems.isEmpty)
        let settings = AppSettings(defaults: TestScratch.defaults("PostSwipeTests"))
        #expect(settings.postLeadingSwipeLayout.swipeItems.isEmpty)
        #expect(settings.postTrailingSwipeLayout.swipeItems.isEmpty)
    }

    /// 「カスタマイズ」のほかは、投稿のメニューの項目と「メニューを開く」「アクションバーを開く」をすべて並びに持ち、選べるようにする。
    @Test func layoutHoldsEveryPlaceableItem() {
        let items = PostSwipeItem.defaultLayout.elements.compactMap { element -> PostSwipeItem? in
            guard case .item(let item, _) = element else { return nil }
            return item
        }
        #expect(Set(items) == Set(PostSwipeItem.allCases))
        #expect(items.count == PostSwipeItem.allCases.count)
        #expect(!items.contains(.status(.customize)))
        #expect(Array(items.prefix(2)) == [.menu, .actionBar])
    }

    @Test func rawValuesRoundTrip() {
        for item in PostSwipeItem.allCases {
            #expect(PostSwipeItem(rawValue: item.rawValue) == item)
        }
        #expect(PostSwipeItem(rawValue: "customize") == nil)
    }

    /// 右と左の並びを別々に保存し、並べた順を保つ。
    @Test func persistsBothSidesSeparately() {
        let defaults = TestScratch.defaults("PostSwipeTests")
        let settings = AppSettings(defaults: defaults)
        settings.postLeadingSwipeLayout = layout(showing: [.status(.favourite), .status(.reblog)])
        settings.postTrailingSwipeLayout = layout(showing: [.menu, .status(.reply)])
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.postLeadingSwipeLayout.swipeItems == [.status(.favourite), .status(.reblog)])
        #expect(relaunched.postTrailingSwipeLayout.swipeItems == [.menu, .status(.reply)])
    }

    /// タップ、長押し、どちらのスワイプでも、「アクションバーを開く」を割り当てていれば事前に準備する。
    @Test func actionBarGestureIncludesSwipes() {
        let settings = AppSettings(defaults: TestScratch.defaults("PostSwipeTests"))
        #expect(!settings.opensActionBarByGesture)
        settings.postLeadingSwipeLayout = layout(showing: [.actionBar])
        #expect(settings.opensActionBarByGesture)
        settings.postLeadingSwipeLayout = PostSwipeItem.defaultLayout
        settings.postTrailingSwipeLayout = layout(showing: [.actionBar])
        #expect(settings.opensActionBarByGesture)
        settings.postTrailingSwipeLayout = PostSwipeItem.defaultLayout
        var actions = settings.statusActions
        actions.longPress = .actionBar
        settings.statusActions = actions
        #expect(settings.opensActionBarByGesture)
    }

    /// `shown`を、その順で並びの先頭に出す。残りは既定の順で隠したまま後ろに置く。
    private func layout(showing shown: [PostSwipeItem]) -> MenuLayout<PostSwipeItem> {
        let rest = PostSwipeItem.defaultLayout.elements.filter { element in
            guard case .item(let item, _) = element else { return true }
            return !shown.contains(item)
        }
        return MenuLayout(elements: shown.map { .item($0, isVisible: true) } + rest)
    }
}
