import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// お知らせのシートの一覧。決まりはdocs/announcements.mdにある。
@MainActor
struct AnnouncementsViewControllerTests {
    nonisolated private static func announcement(_ id: String, at offset: TimeInterval, read: Bool = true) -> Announcement {
        let body = String(repeating: "お知らせ\(id)の本文を何行にもわたって書く。", count: 6)
        return Announcement(id: id, content: "<p>\(body)</p>", publishedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), read: read)
    }

    /// 一覧を出したウィンドウ。
    private func show(_ model: AnnouncementsModel) throws -> (UIWindow, AnnouncementsViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let controller = AnnouncementsViewController(model: model, completion: TextInputCompletion(completion: ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)), recentEmojis: nil))
        window.rootViewController = AnnouncementsNavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, controller)
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    private static func entries(in view: UIView) -> [AnnouncementEntryView] {
        if let entry = view as? AnnouncementEntryView { return [entry] }
        return view.subviews.flatMap(entries(in:))
    }

    /// 下へ読み進めている間に、上へお知らせが届いても、読んでいる行を画面の同じ位置に保つ。
    @Test func keepsReadingRowWhenAnnouncementArrivesAbove() async throws {
        let rows = (0..<6).map { Self.announcement("\($0)", at: TimeInterval($0)) }
        let operations = AnnouncementsModel.Operations(list: { AnnouncementList(announcements: rows) }, dismiss: { _ in }, addReaction: { _, _ in }, removeReaction: { _, _ in })
        let model = AnnouncementsModel(operations: operations, streamingHub: nil, tasks: TaskScope()) {}
        let (window, controller) = try show(model)
        try await waitUntil { model.contentState == .loaded }
        controller.view.layoutIfNeeded()
        let scrollView = try #require(Self.scrollView(in: controller.view))
        scrollView.contentOffset.y = 500
        let reading = try #require(Self.entries(in: scrollView).first { $0.convert($0.bounds, to: nil).maxY > 200 })
        let before = reading.convert(reading.bounds, to: nil).minY

        model.apply(.announcement(Self.announcement("new", at: 100)))
        controller.view.layoutIfNeeded()

        #expect(reading.convert(reading.bounds, to: nil).minY == before)
        window.isHidden = true
    }

    /// 下へ読み進めている間に、読んでいる行のすぐ上の行が取り下げられても、下に見えている行を動かさない。
    @Test func keepsReadingRowWhenTopRowIsDeleted() async throws {
        let rows = (0..<6).map { Self.announcement("\($0)", at: TimeInterval($0)) }
        let operations = AnnouncementsModel.Operations(list: { AnnouncementList(announcements: rows) }, dismiss: { _ in }, addReaction: { _, _ in }, removeReaction: { _, _ in })
        let model = AnnouncementsModel(operations: operations, streamingHub: nil, tasks: TaskScope()) {}
        let (window, controller) = try show(model)
        try await waitUntil { model.contentState == .loaded }
        controller.view.layoutIfNeeded()
        let scrollView = try #require(Self.scrollView(in: controller.view))
        scrollView.contentOffset.y = 500
        let entries = Self.entries(in: scrollView).sorted { $0.frame.minY < $1.frame.minY }
        let topIndex = try #require(entries.firstIndex { $0.convert($0.bounds, to: nil).maxY > scrollView.convert(CGPoint(x: 0, y: scrollView.contentOffset.y + scrollView.adjustedContentInset.top), to: nil).y })
        let below = entries[topIndex + 1]
        let before = below.convert(below.bounds, to: nil).minY
        // 並びは新しい順なので、上からn番目の行のIDは5-n。
        model.apply(.announcementDelete(announcementID: "\(5 - topIndex)"))
        controller.view.layoutIfNeeded()

        #expect(below.convert(below.bounds, to: nil).minY == before)
        window.isHidden = true
    }

    /// 描き直しても、同じリアクションのボタンは作り替えない。押している途中のタップを取り消さないため。
    @Test func reusesReactionButtonsOnRedraw() {
        let view = AnnouncementReactionsView()
        let reaction = AnnouncementReactionsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: 1, isMine: false, spokenName: "👍")
        view.apply([reaction])
        let first = view.subviews.first { $0.accessibilityLabel == "👍 1件" }

        view.apply([AnnouncementReactionsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: 2, isMine: true, spokenName: "👍")])

        #expect(first != nil)
        #expect(view.subviews.first { $0.accessibilityLabel == "👍 2件" } === first)
    }

    /// 既読の送信が失敗して未読に戻り、一覧を描き直しても、行が画面の外から入ってくるまで送り直さない。
    @Test func doesNotResendDismissOnRedraw() async throws {
        let dismissals = Mutex(0)
        let operations = AnnouncementsModel.Operations(
            list: { AnnouncementList(announcements: [Self.announcement("1", at: 0, read: false)]) },
            dismiss: { _ in
                dismissals.withLock { $0 += 1 }
                throw MastodonAPIError(statusCode: 500, message: "Internal Server Error")
            },
            addReaction: { _, _ in },
            removeReaction: { _, _ in }
        )
        let model = AnnouncementsModel(operations: operations, streamingHub: nil, tasks: TaskScope()) {}
        let (window, controller) = try show(model)
        try await waitUntil { model.contentState == .loaded && dismissals.withLock { $0 } == 1 && model.unreadCount == 1 && model.runningTaskCount == 0 }

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        #expect(model.runningTaskCount == 0)
        #expect(dismissals.withLock { $0 } == 1)
        window.isHidden = true
    }
}
