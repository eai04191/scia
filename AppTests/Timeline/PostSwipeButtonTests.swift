import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 投稿のスワイプで出すボタン。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
@MainActor
@Suite(.scratch, .serialized, .failureState)
struct PostSwipeButtonTests {
    /// 投稿のメニューが空になる投稿では、選択しても何も起きないので「メニュー」のボタンを出さない。
    @Test func menuButtonIsHiddenWhenMenuIsEmpty() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        // 編集された投稿でだけ出る項目だけを並べると、編集されていない投稿ではメニューが空になる。
        harness.settings.statusMenuLayout = MenuLayout(elements: StatusMenuItem.defaultLayout.elements.map { element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: item == .editHistory)
        })
        harness.settings.postTrailingSwipeLayout = MenuLayout(elements: [.item(.menu, isVisible: true), .item(.status(.reply), isVisible: true)])
        harness.setStatuses(StatusFactory.make(count: 5, startingAt: 1_000))
        harness.scroll(toFraction: 0)

        let configuration = try #require(harness.viewController.postSwipe(at: IndexPath(item: 0, section: 0), side: .trailing))

        #expect(configuration.actions.map(\.title) == ["返信"])
    }

    /// 投稿と同じ見た目で出す通知にも、投稿のスワイプを出し、通知でだけ出る項目も選択できる。再掲する通知には出さない。
    @Test func notificationsLookingLikePostsAreSwipedAsPosts() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.postTrailingSwipeLayout = MenuLayout(elements: [.item(.status(.dismissNotification), isVisible: true), .item(.status(.reply), isVisible: true)])
        let status = StatusFactory.make(count: 1, startingAt: 1_000)[0]
        harness.viewController.setEntries([
            .notification(MastodonNotification(id: "n1", type: .mention, createdAt: status.createdAt, account: status.account, status: status)),
            .notification(MastodonNotification(id: "n2", type: .favourite, createdAt: status.createdAt, account: status.account, status: status)),
        ])
        harness.scroll(toFraction: 0)

        let configuration = try #require(harness.viewController.postSwipe(at: IndexPath(item: 0, section: 0), side: .trailing))
        #expect(configuration.actions.map(\.title) == ["通知を削除", "返信"])
        #expect(harness.viewController.postSwipe(at: IndexPath(item: 1, section: 0), side: .trailing) == nil)
    }

    /// メニューに項目があれば、「メニュー」のボタンを出す。
    @Test func menuButtonIsShownWhenMenuHasItems() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.statusMenuLayout = MenuLayout(elements: [.item(.reply, isVisible: true)])
        harness.settings.postTrailingSwipeLayout = MenuLayout(elements: [.item(.menu, isVisible: true)])
        harness.setStatuses(StatusFactory.make(count: 5, startingAt: 1_000))
        harness.scroll(toFraction: 0)

        let configuration = try #require(harness.viewController.postSwipe(at: IndexPath(item: 0, section: 0), side: .trailing))

        #expect(configuration.actions.map(\.title) == ["メニュー"])
    }
}
