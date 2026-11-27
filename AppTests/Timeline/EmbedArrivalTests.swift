import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// リンクカードから、読み終えたXの投稿のカードに替わるときの見え方。
@Suite(.scratch, .failureState)
@MainActor
struct EmbedArrivalTests {
    private func card() throws -> LinkCardView.Content {
        let url = try #require(URL(string: "https://x.com/dummy/status/1"))
        return LinkCardView.Content(card: .link(url), padding: 10, transitionDuration: 0.4, thumbnailSide: .left, typography: .standard)
    }

    private func embed() -> EmbeddedPostView.Content {
        EmbeddedPostView.Content(
            id: "x-1",
            header: nil,
            avatarSize: 20,
            text: NSAttributedString(string: "届いたXの投稿"),
            openActionName: "開く",
            padding: 10,
            avatarNameSpacing: 6,
            headerSpacing: 6,
            mediaSpacing: 8,
            transitionDuration: 0.4
        )
    }

    private func body(statusID: Status.ID, card: LinkCardView.Content?, embed: EmbeddedPostView.Content?) -> PostBodyContent {
        var content = PostBodyContent(text: NSAttributedString(string: "本文 x.com/dummy/status/1"), mediaSpacing: 8)
        content.card = card
        content.cardSpacing = 8
        content.embed = embed
        content.embedSpacing = 8
        content.statusID = statusID
        return content
    }

    private func window(showing view: UIView) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        window.addSubview(view)
        view.frame = CGRect(x: 0, y: 100, width: 328, height: 400)
        return window
    }

    /// カードが画面に描かれるまで待つ。描かれる前はスナップショットを取れないため。
    private func waitUntilDrawn(_ view: PostBodyView) async throws {
        view.layoutIfNeeded()
        try await waitUntil { view.linkCard?.snapshotView(afterScreenUpdates: false) != nil }
    }

    /// 同じ投稿のリンクカードがXの投稿のカードに替わったら、リンクカードは1コマで消さず、カードのあった位置にスナップショットを残して薄くする。
    /// Xの投稿のカードは透明からフェードインさせる。
    @Test func cardStaysWhileEmbedFadesIn() async throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(statusID: "1", card: try card(), embed: nil))
        try await waitUntilDrawn(view)
        let cardFrame = try #require(view.linkCard?.frame)

        view.apply(body(statusID: "1", card: try card(), embed: embed()))
        view.layoutIfNeeded()

        #expect(view.linkCard == nil)
        let leaving = try #require(view.leavingCardSnapshot, "替わったカードのスナップショットを残していません")
        #expect(leaving.superview === view)
        #expect(leaving.frame == cardFrame)
        #expect(try #require(view.embed).alpha == 0)
    }

    /// フェードインさせている途中に同じ投稿が再描画されても（絵文字が届いたなど）、Xの投稿のカードの不透明度を1コマで上げない。
    @Test func redrawingSameStatusKeepsEmbedFading() async throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(statusID: "1", card: try card(), embed: nil))
        try await waitUntilDrawn(view)
        view.apply(body(statusID: "1", card: try card(), embed: embed()))

        view.apply(body(statusID: "1", card: try card(), embed: embed()))

        #expect(try #require(view.embed).alpha == 0)
        #expect(view.leavingCardSnapshot != nil)
    }

    /// 入れ替えの途中に注意書きを折りたたんだら、リンクカードのスナップショットを残さない。Xの投稿のカードもリンクカードも隠れるため。
    @Test func collapsingSpoilerDropsLeavingCard() async throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(statusID: "1", card: try card(), embed: nil))
        try await waitUntilDrawn(view)
        view.apply(body(statusID: "1", card: try card(), embed: embed()))
        #expect(view.leavingCardSnapshot != nil)

        var collapsed = body(statusID: "1", card: try card(), embed: embed())
        collapsed.spoiler = PostBodyContent.Spoiler(text: NSAttributedString(string: "注意"), isCollapsed: true, padding: 8, bodySpacing: 8, buttonFont: .preferredFont(forTextStyle: .footnote), buttonSpacing: 4, cornerRadius: 8)
        view.apply(collapsed)

        #expect(view.leavingCardSnapshot == nil)
        #expect(view.embed == nil)
    }

    /// 使い回された行で別の投稿に替わったら、前の投稿のリンクカードのスナップショットを残さず、Xの投稿のカードもすぐ出す。
    @Test func reuseForAnotherStatusDropsLeavingCard() async throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(statusID: "1", card: try card(), embed: nil))
        try await waitUntilDrawn(view)
        view.apply(body(statusID: "1", card: try card(), embed: embed()))
        #expect(view.leavingCardSnapshot != nil)

        view.apply(body(statusID: "2", card: nil, embed: embed()))

        #expect(view.leavingCardSnapshot == nil)
        #expect(try #require(view.embed).alpha == 1)
    }
}

/// Xの投稿を読み終えて行が伸びるときの、タイムラインの行の位置。docs/vision.mdの「タイムラインの動き」のとおり、見えている行は下の行ごと動かして伸ばし、
/// 上端が表示領域より上にある行は、下の行を動かさずに上へ伸ばす。
@Suite(.scratch, .failureState)
@MainActor
struct XPostArrivalScrollTests {
    private func linking(_ base: Status, to id: String) -> Status {
        let link = "https://x.com/dummy/status/\(id)"
        return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: #"<p>Xの投稿 <a href="\#(link)">\#(link)</a></p>"#, spoilerText: "", url: nil)
    }

    private func post(_ id: String) throws -> XPost {
        XPost(
            id: id,
            url: try #require(URL(string: "https://x.com/dummy/status/\(id)")),
            authorName: "ダミー",
            authorScreenName: "dummy",
            text: .plain(String(repeating: "届いたXの投稿の本文。", count: 8), emojis: [])
        )
    }

    private func harness(with statuses: [Status]) throws -> (TimelineHarness, XPostStore) {
        let harness = try TimelineHarness()
        harness.settings.expandsXPosts = true
        let store = XPostStore(retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _ in throw URLError(.notConnectedToInternet) }
        store.reserve(id: "7")
        harness.viewController.xPosts = store
        harness.setStatuses(statuses)
        return (harness, store)
    }

    /// 上端が表示領域より上にある行が伸びたら、伸びた分は表示領域の上へ出し、下の行は動かさない。
    @Test func rowAboveTopGrowsUpward() throws {
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = linking(statuses[10], to: "7")
        let (harness, store) = try harness(with: statuses)
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 20
        harness.collectionView.layoutIfNeeded()
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.frame.height)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        let belowY = try #require(harness.windowMinY(of: below))
        let belowCell = try #require(harness.visibleCell(of: below))

        store.deliver(try post("7"))
        harness.viewController.applyXPost(id: "7")

        let grown = try #require(harness.visibleCell(of: id)?.frame.height) - height
        #expect(grown > 0, "Xの投稿のカードに替わって行が伸びていません")
        #expect(try abs(#require(harness.windowMinY(of: id)) - (y - grown)) < 0.5, "伸びた分が上へ出ていません")
        #expect(try abs(#require(harness.windowMinY(of: below)) - belowY) < 0.5, "下の行が動きました")
        #expect(belowCell.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } != true, "動かない下の行に動きを付けています")
        #expect(harness.visibleCell(of: id)?.layer.mask == nil, "上へ伸びた行を切り抜いています")
        // 伸びた行を、伸びた分だけ下から滑らせると、伸びた中身が下の行に重なって見える。
        #expect(harness.visibleCell(of: id)?.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } != true, "上へ伸びた行そのものを動かしました")
    }

    /// 見えている行が大きく伸びて、下の何行もが表示領域の外へ押し出されるときは、押し出される行をどれも1コマで消さず、
    /// 再描画する前のスナップショットを動かして外へ送る。
    @Test func largeGrowthSendsOutEveryPushedRow() async throws {
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = linking(statuses[10], to: "7")
        let (harness, store) = try harness(with: statuses)
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.layoutIfNeeded()
        // 描かれる前の行はスナップショットを取れないため、描かれるのを待つ。
        try await waitUntil { harness.collectionView.visibleCells.allSatisfy { $0.snapshotView(afterScreenUpdates: false) != nil } }
        let before = Set(harness.collectionView.visibleCells.map(ObjectIdentifier.init))

        let long = XPost(
            id: "7",
            url: try #require(URL(string: "https://x.com/dummy/status/7")),
            authorName: "ダミー",
            authorScreenName: "dummy",
            text: .plain(String(repeating: "とても長いXの投稿の本文。", count: 80), emojis: [])
        )
        store.deliver(long)
        harness.viewController.applyXPost(id: "7")
        harness.collectionView.layoutIfNeeded()

        let pushedOut = before.subtracting(harness.collectionView.visibleCells.map(ObjectIdentifier.init))
        #expect(pushedOut.count >= 2, "複数の行が押し出される条件になっていません")
        let sentOut = harness.collectionView.subviews.filter { !($0 is UICollectionViewCell) && $0.layer.animation(forKey: "rowShiftEnd") != nil }
        #expect(sentOut.count >= pushedOut.count, "押し出された行のスナップショットを動かしていません")
        // 替わったリンクカードのスナップショットは、本文が自分で薄くして外す。新しく現れた部品として切り抜くと、見えていたスナップショットが最初のコマで隠れる。
        let leaving = try #require((harness.visibleCell(of: id)?.contentView as? PostContentView)?.postBody.leavingCardSnapshot, "替わったカードのスナップショットを残していません")
        #expect(leaving.layer.mask == nil, "薄くして消すカードのスナップショットを切り抜いています")
    }

    /// 見えている行が伸びたら、上の行は動かさず、下の行を伸びた分だけ押し下げる。
    @Test func visibleRowPushesRowsBelow() throws {
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = linking(statuses[10], to: "7")
        let (harness, store) = try harness(with: statuses)
        defer { harness.tearDown() }
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let above = TimelineViewController.ItemID.status(statuses[9].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let aboveY = try #require(harness.windowMinY(of: above))
        let y = try #require(harness.windowMinY(of: id))
        let belowY = try #require(harness.windowMinY(of: below))
        let height = try #require(harness.visibleCell(of: id)?.frame.height)

        store.deliver(try post("7"))
        harness.viewController.applyXPost(id: "7")
        harness.collectionView.layoutIfNeeded()

        let grown = try #require(harness.visibleCell(of: id)?.frame.height) - height
        #expect(grown > 0, "Xの投稿のカードに替わって行が伸びていません")
        #expect(harness.windowMinY(of: above) == aboveY)
        #expect(harness.windowMinY(of: id) == y)
        #expect(try abs(#require(harness.windowMinY(of: below)) - (belowY + grown)) < 0.5)
    }
}
