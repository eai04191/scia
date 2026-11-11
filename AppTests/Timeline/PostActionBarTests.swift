import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿のアクションバーと、その引き出しの開閉。決まりはdocs/post-action-bar.mdにある。
@MainActor
@Suite(.scratch)
struct PostActionBarTests {
    private func harness() throws -> (harness: TimelineHarness, statuses: [Status]) {
        let harness = try TimelineHarness()
        // 引き出しの開閉を確かめるため、いつも出す設定を外す。
        harness.settings.appearance.showsActionBar = false
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(statuses[10].id), at: .centeredVertically)
        return (harness, statuses)
    }

    private func bar(in harness: TimelineHarness, of id: Status.ID) -> PostActionBarView? {
        (harness.visibleCell(of: .status(id))?.contentView as? PostContentView)?.postBody.actionBar
    }

    private func hasRowShift(_ view: UIView) -> Bool {
        view.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true
    }

    /// いつも出す設定でなければどの投稿にも出さず、いつも出す設定にすると、タイムラインの投稿に出す。
    @Test func showsOnlyWhenTurnedOnOrOpened() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        #expect(bar(in: harness, of: statuses[10].id) == nil)

        harness.settings.appearance.showsActionBar = true
        harness.viewController.reconfigure(Set(statuses.map { .status($0.id) }))

        let shown = try #require(bar(in: harness, of: statuses[10].id))
        #expect(shown.content?.buttons.map(\.item) == PostActionBarItem.defaultLayout.actionBarItems)
    }

    /// スレッドの中心の投稿にも、ほかの投稿と同じく出す。
    @Test func showsOnThreadFocus() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        harness.viewController.threadFocusID = statuses[10].id
        harness.settings.appearance.showsActionBar = true
        harness.viewController.reconfigure(Set(statuses.map { .status($0.id) }))

        #expect(bar(in: harness, of: statuses[10].id) != nil)
        #expect(bar(in: harness, of: statuses[11].id) != nil)
    }

    /// 開くと、押した投稿の位置を保って投稿が伸び、下のアイテムを元の位置から動かしてつなぐ。上のアイテムは動かさない。
    @Test func openingKeepsRowAndShiftsRowsBelow() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        harness.viewController.toggleActionBar(for: id)

        #expect(bar(in: harness, of: statuses[10].id) != nil)
        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height)
        // 位置を当て直す計算で、浮動小数の誤差だけずれる。
        #expect(abs(try #require(harness.windowMinY(of: id)) - y) < 0.01)
        #expect(try hasRowShift(#require(harness.visibleCell(of: .status(statuses[11].id)))), "下のアイテムを動かしていません")
        #expect(try !hasRowShift(#require(harness.visibleCell(of: .status(statuses[9].id)))), "上のアイテムを動かしました")
    }

    /// 開くと、アクションバーを上の端から切り抜いて現す。開く前の投稿の下の余白はアクションバーに重なるので、投稿の切り抜きだけでは、重なった部分が最初のコマで見える。
    /// 投稿全体の切り抜きは開く前の高さから広げ、開く前から見えていた中身（短い投稿のアイコンなど）を隠さない。
    @Test func openingRevealsActionBarFromItsTop() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        harness.viewController.toggleActionBar(for: id)

        let bar = try #require(bar(in: harness, of: statuses[10].id))
        let reveal = try #require(bar.layer.mask?.animation(forKey: TimelineViewController.actionBarRevealName) as? CASpringAnimation)
        #expect(reveal.fromValue as? CGFloat == 0)
        let cell = try #require(harness.visibleCell(of: id))
        let grow = try #require(cell.layer.mask?.animation(forKey: "rowGrowth") as? CASpringAnimation)
        #expect(abs((grow.fromValue as? CGFloat ?? 0) - height) < 0.01)
    }

    /// 表示領域の外へ出た行の像のうち、外へ送っている途中のもの。
    private func leavingSnapshots(in harness: TimelineHarness) -> [UIView] {
        harness.collectionView.subviews.filter { $0.layer.animation(forKey: "rowShiftEnd") != nil }
    }

    /// 下の端の近くで開くと、表示領域の外へ押し出されるアイテムを、像で外へ送る。閉じるだけなら、下のアイテムは上がってくるだけなので像を取らない。
    @Test func openingNearBottomSendsOutPushedItems() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        // 一番下に見えているアイテムの上端を、表示領域の下端から10ptのところに置き、その1つ上の投稿で開いて押し出す。
        func visiblePosts() -> [(id: Status.ID, frame: CGRect)] {
            harness.collectionView.visibleCells.compactMap { cell -> (Status.ID, CGRect)? in
                guard let id = ((cell.contentView as? PostContentView)?.configuration as? PostContentConfiguration)?.statusID else { return nil }
                return (id, cell.convert(cell.bounds, to: nil))
            }.sorted { $0.1.minY < $1.1.minY }
        }
        let visibleBottom = harness.collectionView.convert(harness.collectionView.bounds, to: nil).maxY
        let last = try #require(visiblePosts().last)
        harness.collectionView.contentOffset.y += last.frame.minY - (visibleBottom - 10)
        harness.collectionView.layoutIfNeeded()
        let posts = visiblePosts()
        let pushed = try #require(posts.last)
        #expect(abs(pushed.frame.minY - (visibleBottom - 10)) < 1)
        let target = try #require(posts.dropLast().last?.id)
        let id = TimelineViewController.ItemID.status(target)
        #expect(statuses.contains { $0.id == target })
        // 像は、画面に描いたあとの中身から作るので、描いておく。
        CATransaction.flush()

        harness.viewController.toggleActionBar(for: id)
        #expect(!leavingSnapshots(in: harness).isEmpty, "押し出されるアイテムを外へ送っていません")

        CATransaction.flush()
        let sentBefore = leavingSnapshots(in: harness).count
        harness.viewController.toggleActionBar(for: id)
        #expect(leavingSnapshots(in: harness).count == sentBefore, "閉じるときに、外へ出ないアイテムを外へ送りました")
    }

    /// 開いた投稿の下の端だけが上の端に残る位置で閉じると、その下のアイテムが縮んだ分だけ上がり、上の端から外へ出ることがある。外へ出るアイテムも、像で外へ送る。
    @Test func closingNearTopSendsOutRisingItems() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        // 縮む長さを、下のアイテムの高さより大きくする。
        harness.settings.setValue(100, for: AppearanceCatalog.actionBarPadding)
        // すぐ下の投稿が縮む長さより低い投稿を選ぶ。
        let index = try #require((5..<25).first { index in
            try? harness.scroll(to: .status(statuses[index].id), at: .centeredVertically)
            return (harness.visibleCell(of: .status(statuses[index + 1].id))?.bounds.height ?? .infinity) < 100
        })
        let id = TimelineViewController.ItemID.status(statuses[index].id)
        harness.viewController.toggleActionBar(for: id)
        let opened = try #require(harness.visibleCell(of: id))
        let visibleTop = harness.collectionView.convert(harness.collectionView.bounds, to: nil).minY + harness.collectionView.adjustedContentInset.top
        harness.collectionView.contentOffset.y += opened.convert(opened.bounds, to: nil).maxY - (visibleTop + 5)
        harness.collectionView.layoutIfNeeded()
        // 像は、画面に描いたあとの中身から作るので、描いておく。
        CATransaction.flush()

        harness.viewController.toggleActionBar(for: id)

        #expect(harness.visibleCell(of: .status(statuses[index + 1].id)) == nil, "すぐ下の投稿が上の端から外へ出ていません")
        #expect(!leavingSnapshots(in: harness).isEmpty, "上の端から外へ出るアイテムを外へ送っていません")
    }

    /// 開いている投稿でもう一度開くと閉じ、別の投稿で開くと前の投稿のアクションバーは閉じる。同時に開くのは1つだけ。
    @Test func opensOnlyOneAtATime() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let first = TimelineViewController.ItemID.status(statuses[10].id)
        let second = TimelineViewController.ItemID.status(statuses[12].id)

        harness.viewController.toggleActionBar(for: first)
        harness.viewController.toggleActionBar(for: second)
        #expect(bar(in: harness, of: statuses[10].id) == nil)
        #expect(bar(in: harness, of: statuses[12].id) != nil)

        harness.viewController.toggleActionBar(for: second)
        #expect(bar(in: harness, of: statuses[12].id) == nil)
        #expect(harness.viewController.openActionBarItemID == nil)
    }

    /// 上の投稿のアクションバーを閉じて下の投稿で開いても、押した投稿の画面上の位置は動かない。
    @Test func closingRowAboveKeepsPressedRow() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let above = TimelineViewController.ItemID.status(statuses[10].id)
        let pressed = TimelineViewController.ItemID.status(statuses[11].id)
        harness.viewController.toggleActionBar(for: above)
        let y = try #require(harness.windowMinY(of: pressed))

        harness.viewController.toggleActionBar(for: pressed)

        #expect(abs(try #require(harness.windowMinY(of: pressed)) - y) < 0.01)
    }

    /// いつも出す設定では、開く操作は何もしない。
    @Test func toggleDoesNothingWhenAlwaysShown() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        harness.settings.appearance.showsActionBar = true
        harness.viewController.toggleActionBar(for: .status(statuses[10].id))
        #expect(harness.viewController.openActionBarItemID == nil)
    }

    /// 開くのはタイムラインの投稿だけで、通知には出せない。
    @Test func cannotShowOnNotifications() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let status = StatusFactory.make(count: 1, startingAt: 1_000)[0]
        let notification = MastodonNotification(id: "n1", type: .mention, createdAt: status.createdAt, account: status.account, status: status)
        #expect(harness.viewController.canShowActionBar(in: .status(status)))
        #expect(!harness.viewController.canShowActionBar(in: .notification(notification)))
    }

    private func buttons(in harness: TimelineHarness, of id: Status.ID) -> [PostActionBarButton] {
        bar(in: harness, of: id)?.content?.buttons ?? []
    }

    /// 投稿の本文を置き換えたタイムライン。投稿の位置は同じ。
    private func harness(replacing index: Int, with make: (Status) -> Status, items: [PostActionBarItem]) throws -> (harness: TimelineHarness, statuses: [Status]) {
        let harness = try TimelineHarness()
        harness.settings.appearance.showsActionBar = true
        harness.settings.postActionBarLayout = MenuLayout(elements: PostActionBarItem.defaultLayout.elements.map { element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: items.contains(item))
        })
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[index] = make(statuses[index])
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(statuses[index].id), at: .centeredVertically)
        return (harness, statuses)
    }

    /// 並びを変えたら、出している投稿のボタンも変わる。
    @Test func redrawsWhenLayoutChanges() async throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        harness.settings.appearance.showsActionBar = true
        try await waitUntil { bar(in: harness, of: statuses[10].id) != nil }

        harness.settings.postActionBarLayout = MenuLayout(elements: PostActionBarItem.defaultLayout.elements.map { element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: item == .menu)
        })

        try await waitUntil { buttons(in: harness, of: statuses[10].id).map(\.item) == [.menu] }
    }

    /// カスタム絵文字のある投稿では、「カスタム絵文字」のボタンを押せる色で描く。押したときと同じく、絵文字のメニューを組めるため。
    @Test func customEmojiButtonIsAvailableWhenPostHasEmoji() throws {
        let url = try #require(URL(string: "https://example.social/emoji/blob.png"))
        let emoji = CustomEmoji(shortcode: "blob", url: url, staticUrl: url)
        let (harness, statuses) = try harness(replacing: 10, with: { base in
            Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "<p>:blob:</p>", spoilerText: "", url: nil, emojis: [emoji])
        }, items: [.status(.customEmojis)])
        defer { harness.tearDown() }
        #expect(buttons(in: harness, of: statuses[10].id).map(\.isAvailable) == [true])
    }

    /// 本文を選べる投稿では、初めて組むときから「テキストを選択」のボタンを押せる色で描く。
    @Test func selectTextButtonIsAvailableOnFirstConfiguration() throws {
        let (harness, statuses) = try harness(replacing: 10, with: { $0 }, items: [.status(.selectText)])
        defer { harness.tearDown() }
        #expect(buttons(in: harness, of: statuses[10].id).map(\.isAvailable) == [true])
    }

    /// 投稿のメニューの1段目の項目の名前。まとまりは開いて並べる。
    private func menuTitles(in harness: TimelineHarness, of status: Status, groups: MenuLayout<StatusMenuItem>.Groups? = nil) -> [String] {
        let root = harness.viewController.statusMenu(for: .status(status), id: .status(status.id), groups: groups)?.root
        return (root?.flattenedChildren ?? []).map(\.title)
    }

    /// 投稿のメニューの、サブメニューの中までの項目の名前。「お気に入りした人」などは「その他」のサブメニューに入る。
    private func allMenuTitles(in harness: TimelineHarness, of status: Status) -> [String] {
        func titles(_ nodes: [MenuNode<StatusMenuCommand>]) -> [String] {
            nodes.flatMap { [$0.title] + titles($0.children) }
        }
        return titles(harness.viewController.statusMenu(for: .status(status), id: .status(status.id))?.root.children ?? [])
    }

    /// アクションバーを出している投稿のメニューからは、アクションバーに並べた項目を除く。押せない項目も除く。
    @Test func menuOmitsActionBarItemsWhileShown() throws {
        let (harness, statuses) = try harness(replacing: 10, with: { $0 }, items: [.status(.reply), .status(.bookmark), .status(.edit), .menu])
        defer { harness.tearDown() }
        let titles = menuTitles(in: harness, of: statuses[10])
        #expect(!titles.contains("返信"))
        #expect(!titles.contains("ブックマーク"))
        #expect(titles.contains("ブースト"))
    }

    /// メニューに出すかは設定に従う。アクションバーの項目を表示する設定なら残し、長押しの項目を表示しない設定なら、並べたボタンの長押しの項目を除く。
    @Test func menuRemovalFollowsSettings() throws {
        // 「お気に入りした人」と「ブーストした人」は、数が1以上の投稿のメニューにだけ出る。
        let (harness, statuses) = try harness(replacing: 10, with: { base in
            Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, favouritesCount: 1, reblogsCount: 1)
        }, items: [.status(.reply), .status(.favourite), .menu])
        defer { harness.tearDown() }
        // 既定では、並べたお気に入りのボタンの長押しの項目を出さない。
        #expect(!allMenuTitles(in: harness, of: statuses[10]).contains("お気に入りした人"))

        harness.settings.showsActionBarLongPressItemsInMenu = true
        let shown = allMenuTitles(in: harness, of: statuses[10])
        #expect(shown.contains("お気に入りした人"))
        #expect(!shown.contains("返信"))

        harness.settings.showsActionBarItemsInMenu = true
        harness.settings.showsActionBarLongPressItemsInMenu = false
        let titles = allMenuTitles(in: harness, of: statuses[10])
        #expect(titles.contains("返信"))
        #expect(!titles.contains("お気に入りした人"))
        // ブーストのボタンは並べていないので、その長押しの項目は残す。
        #expect(titles.contains("ブーストした人"))
    }

    /// アクションバーのボタンを押せるかを決めるときは、ハッシュタグの状態を読み直さない。メニューを開かなくても、スクロールで投稿を組むたびに通信するため。ボタンを押してメニューを開いたときは読み直す。
    @Test func actionBarDoesNotRefreshHashtagsUntilMenuOpens() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var refreshes = 0
        harness.viewController.hashtagMenuActions = HashtagMenuActions(mute: HashtagMuteActions(
            known: { _ in false }, refresh: { refreshes += 1 },
            load: { _ in false }, mute: { _, _ in }, unmute: { _ in }
        ))
        harness.settings.appearance.showsActionBar = true
        harness.settings.postActionBarLayout = MenuLayout(elements: PostActionBarItem.defaultLayout.elements.map { element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: item == .status(.hashtags))
        })
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let base = statuses[10]
        statuses[10] = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "<p>#cat</p>", spoilerText: "", url: nil, tags: [Tag(name: "cat", url: nil)])
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(statuses[10].id), at: .centeredVertically)
        #expect(buttons(in: harness, of: statuses[10].id).map(\.isAvailable) == [true])
        #expect(refreshes == 0)

        // アクションバーのボタンを押したときと同じく、1項目のメニューで開く。
        _ = harness.viewController.statusMenu(for: .status(statuses[10]), id: .status(statuses[10].id), groups: .single(.hashtags))
        #expect(refreshes > 0)
    }

    /// 引き出しを閉じている投稿のメニューには、アクションバーに並べた項目も出す。開くと除く。
    @Test func menuKeepsActionBarItemsWhileClosed() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        #expect(menuTitles(in: harness, of: statuses[10]).contains("返信"))
        harness.viewController.toggleActionBar(for: .status(statuses[10].id))
        #expect(!menuTitles(in: harness, of: statuses[10]).contains("返信"))
    }

    /// アクションバーを出している投稿の中の、引用の囲みのメニューからは除かない。アクションバーは引用元への操作ではないため。
    @Test func quotedPostMenuKeepsActionBarItems() throws {
        let (harness, statuses) = try harness(replacing: 10, with: { $0 }, items: [.status(.reply), .menu])
        defer { harness.tearDown() }
        let quoted = statuses[20]
        let titles = harness.viewController.statusMenu(for: .status(quoted), id: .status(statuses[10].id))?.root.flattenedChildren.map(\.title) ?? []
        #expect(titles.contains("返信"))
    }

    /// 投稿のタップに「アクションバーを開く」を選んでいても、引用の囲みは引用の投稿の操作に従い、タップで引用元のスレッドを開く。
    @Test func quotedPostTapFollowsItsOwnActions() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        harness.settings.statusActions.tap = .actionBar
        var opened = 0
        let target = harness.viewController.statusTarget(for: statuses[20], id: .status(statuses[10].id)) { _ in opened += 1 }
        target.perform(.tap, in: harness.viewController.view, at: .zero)
        #expect(opened == 1)
    }

    /// ほかのメニューの中から開く投稿のメニュー（並びを渡して組むもの）からは、除かない。
    @Test func submenuKeepsActionBarItems() throws {
        let (harness, statuses) = try harness(replacing: 10, with: { $0 }, items: [.status(.reply), .menu])
        defer { harness.tearDown() }
        let groups = harness.settings.statusMenuLayout.submenuGroups(actions: harness.settings.statusActions)
        #expect(menuTitles(in: harness, of: statuses[10], groups: groups).contains("返信"))
    }

    /// 閉じると、縮む前の像を投稿に重ねて下から縮め、下のアイテムを元の位置から動かしてつなぐ。
    @Test func closingConcealsActionBarFromBelow() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        harness.viewController.toggleActionBar(for: id)
        let cell = try #require(harness.visibleCell(of: id) as? TimelineCell)
        // 閉じる前の像は、画面に描いたあとの中身から作るので、開いた中身を描いておく。
        CATransaction.flush()

        harness.viewController.toggleActionBar(for: id)

        #expect(cell.isShowingShrinkSnapshot)
        #expect(try hasRowShift(#require(harness.visibleCell(of: .status(statuses[11].id)))), "下のアイテムを動かしていません")
    }

    /// アクションバーを出した投稿の中身と、1つ目のボタン。`spacing`と`bottom`は「本文とのあいだ」と「下の余白」。
    private func laidOutBar(spacing: CGFloat, bottom: CGFloat) throws -> (harness: TimelineHarness, content: PostContentView, button: PostActionBarButtonView) {
        let harness = try TimelineHarness()
        harness.settings.appearance.showsActionBar = true
        harness.settings.setValue(spacing, for: AppearanceCatalog.actionBarSpacing)
        harness.settings.setValue(bottom, for: AppearanceCatalog.rowPaddingBottom)
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        try harness.scroll(to: .status(statuses[10].id), at: .centeredVertically)
        let content = try #require(harness.visibleCell(of: .status(statuses[10].id))?.contentView as? PostContentView)
        content.layoutIfNeeded()
        let button = try #require(content.postBody.actionBar?.shownButtons.first)
        return (harness, content, button)
    }

    /// `content`の座標で、ボタンの中央の列の高さ`y`を押すと受けるビュー。
    private func hit(_ content: PostContentView, button: PostActionBarButtonView, y: CGFloat) -> UIView? {
        content.hitTest(CGPoint(x: button.convert(button.bounds, to: content).midX, y: y), with: nil)
    }

    /// バーの上の「本文とのあいだ」と、下の「下の余白」も押せる。本文より上とアイテムの外は押せない。
    @Test func blankAroundBarReachesButton() throws {
        let (harness, content, button) = try laidOutBar(spacing: 8, bottom: 15)
        defer { harness.tearDown() }
        let frame = button.convert(button.bounds, to: content)

        #expect(hit(content, button: button, y: frame.minY - 7) === button)
        #expect(hit(content, button: button, y: frame.midY + 21) === button)
        #expect(hit(content, button: button, y: frame.minY - 9) !== button)
        #expect(hit(content, button: button, y: content.bounds.maxY + 1) !== button)
        #expect(button.point(inside: button.convert(CGPoint(x: frame.midX, y: frame.midY + 21), from: content), with: nil), "指を離す位置をボタンの外と扱うと、押したことになりません")
    }

    /// ボタンの上で指を止めてから動かしても、スクロールに切り替わる。押せる範囲を空きまで広げたので、切り替わらないと、空きから始めたスクロールが効かない。
    @Test func draggingFromButtonScrolls() throws {
        let (harness, _, button) = try laidOutBar(spacing: 8, bottom: 15)
        defer { harness.tearDown() }

        #expect(harness.viewController.collectionView.touchesShouldCancel(in: button))
    }

    /// 余白が広くても、押せる高さはアイコンの中心から上下22ptまでにする。
    @Test func reachStopsAtMinimumTapTarget() throws {
        let (harness, content, button) = try laidOutBar(spacing: 40, bottom: 40)
        defer { harness.tearDown() }
        let frame = button.convert(button.bounds, to: content)

        #expect(hit(content, button: button, y: frame.midY - 21) === button)
        #expect(hit(content, button: button, y: frame.midY + 21) === button)
        #expect(hit(content, button: button, y: frame.midY - 23) !== button)
        #expect(hit(content, button: button, y: frame.midY + 23) !== button)
    }

    /// ボタンは、アイコンの左も押せる。境目をアイコンの左端から左へずらし、アイコンの少し左を押して左隣の操作にならないようにする。
    @Test func buttonReachesLeftOfIcon() throws {
        let (harness, content, first) = try laidOutBar(spacing: 8, bottom: 15)
        defer { harness.tearDown() }
        let bar = try #require(content.postBody.actionBar)
        let second = try #require(bar.shownButtons.dropFirst().first)
        let reach = try #require(bar.content?.leadingHitReach)
        let frame = second.convert(second.bounds, to: content)
        #expect(reach > 2)

        #expect(content.hitTest(CGPoint(x: frame.minX - reach + 1, y: frame.midY), with: nil) === second)
        #expect(content.hitTest(CGPoint(x: frame.minX - reach - 1, y: frame.midY), with: nil) === first)
        #expect(content.hitTest(CGPoint(x: frame.minX - reach + 1, y: frame.minY - 7), with: nil) === second, "上の空きでも同じ境目にします")
    }

    /// 先頭のボタンは、バーの外の余白へ同じだけ広げる。
    @Test func firstButtonReachesOutsideBar() throws {
        let (harness, content, first) = try laidOutBar(spacing: 8, bottom: 15)
        defer { harness.tearDown() }
        let reach = try #require(content.postBody.actionBar?.content?.leadingHitReach)
        let frame = first.convert(first.bounds, to: content)

        #expect(content.hitTest(CGPoint(x: frame.minX - reach + 1, y: frame.midY), with: nil) === first)
        #expect(content.hitTest(CGPoint(x: frame.minX - reach - 1, y: frame.midY), with: nil) !== first)
    }

    /// 等分した枠は、浮動小数の誤差だけ離れることがある。その境目の点も、ボタンが受ける。
    @Test func boundaryBetweenButtonsReachesButton() {
        let items = StatusMenuItem.allCases.prefix(5)
        let buttons = items.map { PostActionBarButton(item: .status($0), title: "", symbolName: "star", count: nil, isOn: false, tint: .none, isAvailable: true) }
        let bar = PostActionBarView()
        bar.apply(PostActionBarContent(buttons: buttons, iconSize: 18, padding: 6, countFont: .systemFont(ofSize: 13), lightFavouriteIsYellow: false, leadingHitReach: 9, statusID: nil))
        // この幅で、2つ目の右端が113.0、3つ目の左端が113.00000000000001になる。
        bar.frame = CGRect(x: 0, y: 0, width: 282.5, height: 30)
        bar.layoutIfNeeded()

        for button in bar.shownButtons.dropFirst() {
            #expect(bar.hitTest(CGPoint(x: button.frame.minX.nextDown, y: 15), with: nil) is PostActionBarButtonView)
            #expect(bar.hitTest(CGPoint(x: button.frame.minX.rounded(), y: 15), with: nil) is PostActionBarButtonView)
        }
    }

    /// ボタンが多くて狭いときは、広げる長さを、アイコンの左右の空きの半分で止める。止めないと、アイコンの右がほとんど右隣のボタンのものになる。
    @Test func reachStopsAtHalfOfBlankBesideIcon() throws {
        let items = PostActionBarItem.allCases.prefix(10)
        let buttons = items.map { PostActionBarButton(item: $0, title: "", symbolName: "star", count: nil, isOn: false, tint: .none, isAvailable: true) }
        let bar = PostActionBarView()
        bar.apply(PostActionBarContent(buttons: buttons, iconSize: 14, padding: 6, countFont: .systemFont(ofSize: 13), lightFavouriteIsYellow: false, leadingHitReach: 7, statusID: nil))
        bar.frame = CGRect(x: 0, y: 0, width: 220, height: 26)
        bar.layoutIfNeeded()
        let shown = bar.shownButtons
        try #require(shown.count == 10)
        let icon = try #require(bar.iconFrames(in: bar).dropFirst().first)
        let blank = shown[1].frame.maxX - icon.maxX
        try #require(blank > 2 && blank < 14)

        #expect(bar.hitTest(CGPoint(x: icon.minX - blank / 2 + 0.5, y: 13), with: nil) === shown[1])
        #expect(bar.hitTest(CGPoint(x: icon.minX - blank / 2 - 0.5, y: 13), with: nil) === shown[0])
        #expect(bar.hitTest(CGPoint(x: icon.maxX + blank / 2 - 0.5, y: 13), with: nil) === shown[1])
    }

    /// 「投稿の見た目」のプレビューの見本のボタンは、押しても何もしない。
    @Test func previewButtonsDoNothing() throws {
        let configuration = PostContentConfiguration.withActionBarPress()
        #expect(TimelineViewController.keepingOnlyLinks(configuration).onActionBarPress == nil)
    }

    /// 閉じる途中に同じ投稿を描き直したら、閉じる前の像を外す。残すと、新しい中身の手前に古い中身が見える。
    @Test func redrawWhileClosingRemovesSnapshot() throws {
        let (harness, statuses) = try harness()
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        harness.viewController.toggleActionBar(for: id)
        let cell = try #require(harness.visibleCell(of: id) as? TimelineCell)
        CATransaction.flush()
        harness.viewController.toggleActionBar(for: id)
        #expect(cell.isShowingShrinkSnapshot)

        harness.viewController.reconfigure([id])

        #expect(!cell.isShowingShrinkSnapshot)
    }

    /// 長押しして出すメニューは、ブーストとお気に入りのボタンにだけ付け、投稿のメニューと同じ組み方で組む。
    @Test func longPressMenusOnlyOnReblogAndFavourite() throws {
        let (harness, statuses) = try harness(replacing: 10, with: { base in
            Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, favouritesCount: 3)
        }, items: [.status(.reply), .status(.favourite), .menu])
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        #expect(harness.viewController.actionBarLongPressTarget(for: .status(.reply), id: id) == nil)
        #expect(harness.viewController.actionBarLongPressTarget(for: .menu, id: id) == nil)
        let menu = try #require(harness.viewController.actionBarLongPressTarget(for: .status(.favourite), id: id)?.menu())
        #expect(menu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.map(\.title) == ["お気に入りした人"])
    }
}

private extension PostContentConfiguration {
    /// ボタンを押したときの処理を付けた、見本の投稿の中身。
    @MainActor
    static func withActionBarPress() -> PostContentConfiguration {
        let timeline = TimelineViewController(texts: .home, refresh: {})
        let status = StatusFactory.make(count: 1, startingAt: 1_000)[0]
        var configuration = timeline.contentConfiguration(for: status, base: .cell())
        configuration.onActionBarPress = { _, _ in }
        return configuration
    }
}

/// アクションバーのボタンに添える件数の出し方。
@MainActor
@Suite(.scratch)
struct PostActionBarCountFitTests {
    private func bar(width: CGFloat, items: [PostActionBarItem]) -> PostActionBarView {
        let status = Status(
            id: "1",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil),
            content: "<p>a</p>",
            spoilerText: "",
            url: nil,
            favouritesCount: 7_777,
            reblogsCount: 8_888,
            repliesCount: 9_999
        )
        let view = PostActionBarView(frame: CGRect(x: 0, y: 0, width: width, height: 40))
        view.apply(PostActionBarContent(
            buttons: PostActionBarButton.buttons(for: status, items: items, showsCounts: true) { _ in true },
            iconSize: 16,
            padding: 8,
            countFont: .preferredFont(forTextStyle: .subheadline),
            lightFavouriteIsYellow: false,
            leadingHitReach: 8,
            statusID: status.id
        ))
        view.layoutIfNeeded()
        return view
    }

    /// 文字を小さくしても入らないボタンでは、切れた数を見せないよう、件数を出さない。読み上げでは件数を読む。
    @Test func hidesCountsThatDoNotFit() {
        let items: [PostActionBarItem] = [.status(.reply), .status(.reblog), .status(.favourite), .status(.bookmark), .status(.quote), .status(.share), .status(.copyLink), .menu]
        let view = bar(width: 300, items: items)
        #expect(view.countFrames(in: view).isEmpty)
        #expect(view.shownButtons.first?.accessibilityValue == "9,999件")
    }

    /// 入るボタンでは件数を出す。
    @Test func showsCountsThatFit() {
        let view = bar(width: 340, items: PostActionBarItem.defaultLayout.actionBarItems)
        #expect(view.countFrames(in: view).count == 3)
    }
}
