import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// リンクカードから、読み終えたXの投稿の囲みに替わるときの見え方。
@Suite(.scratch)
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

    /// カードが画面に描かれるまで待つ。描かれる前は像を取れないため。
    private func waitUntilDrawn(_ view: PostBodyView) async throws {
        view.layoutIfNeeded()
        try await waitUntil { view.linkCard?.snapshotView(afterScreenUpdates: false) != nil }
    }

    /// 同じ投稿のリンクカードが囲みに替わったら、カードは1コマで消さず、カードのあった位置に像を残して薄くする。
    /// 囲みは透明から浮かび上がらせる。
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
        let leaving = try #require(view.leavingCardSnapshot, "替わったカードの像を残していません")
        #expect(leaving.superview === view)
        #expect(leaving.frame == cardFrame)
        #expect(try #require(view.embed).alpha == 0)
    }

    /// 浮かび上がらせている途中に同じ投稿が描き直されても（絵文字が届いたなど）、囲みを1コマで濃くしない。
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

    /// 入れ替えの途中に注意書きを折りたたんだら、カードの像を残さない。囲みもカードも隠れるため。
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

    /// 使い回された行で別の投稿に替わったら、前の投稿のカードの像を残さず、囲みもすぐ出す。
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

/// Xの投稿を読み終えて行が伸びるときの、一覧の行の位置。docs/vision.mdの「一覧の動き」のとおり、見えている行は下の行ごと動かして伸ばし、
/// 上端が表示領域より上にある行は、伸びても画面上の位置を保つ。
@Suite(.scratch)
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
        harness.tuning.setValue(true, for: TuningCatalog.xPostEmbeds)
        let store = XPostStore(retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _ in throw URLError(.notConnectedToInternet) }
        store.reserve(id: "7")
        harness.viewController.xPosts = store
        harness.setStatuses(statuses)
        return (harness, store)
    }

    /// 上端が表示領域より上にある行が伸びても、その行の画面上の位置は動かない。
    @Test func rowAboveTopKeepsPosition() throws {
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

        store.deliver(try post("7"))
        harness.viewController.applyXPost(id: "7")

        #expect(try #require(harness.visibleCell(of: id)?.frame.height) > height, "囲みに替わって行が伸びていません")
        #expect(harness.windowMinY(of: id) == y)
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
        #expect(grown > 0, "囲みに替わって行が伸びていません")
        #expect(harness.windowMinY(of: above) == aboveY)
        #expect(harness.windowMinY(of: id) == y)
        #expect(try abs(#require(harness.windowMinY(of: below)) - (belowY + grown)) < 0.5)
    }
}
