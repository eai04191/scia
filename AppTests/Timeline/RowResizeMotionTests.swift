import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 行の高さが変わる描き直しを、原因によらず、下の行ごと動かしてつなぐことを確かめる（docs/vision.mdの「タイムラインの動き」）。
@MainActor
@Suite(.scratch, .failureState)
struct RowResizeMotionTests {
    private func hasRowShift(_ view: UIView) -> Bool {
        view.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true
    }

    private func replacing(_ base: Status, content: String, spoilerText: String = "") -> Status {
        Status(id: base.id, createdAt: base.createdAt, account: base.account, content: content, spoilerText: spoilerText, url: nil)
    }

    /// 注意書きを開くと、下の行を元の位置から動かす。閉じると、なくなる本文の像を重ねて下の端から縮め、下の行が詰めてくる前に空きを見せない。
    /// 切り抜きの境は、行の下端ではなく、短いほうの中身の下の端にする。行の下端にすると、開き始めは余白だった部分に本文が1コマで見え、
    /// 閉じ始めは余白になる部分の本文が1コマで消える。
    @Test func togglingSpoilerShiftsRowsBelowAndConcealsShrink() async throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "注意書きの下の本文。", count: 20) + "</p>", spoilerText: "注意書き")
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let closed = try #require(harness.visibleCell(of: id))
        let height = closed.bounds.height
        let contentBottom = height - (try #require(closed.contentView as? PostContentView)).rowBottomMargin

        harness.viewController.toggleSpoiler(of: statuses[10], keeping: id)

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "注意書きを開いても行が伸びていません")
        let grow = try #require(harness.visibleCell(of: id)?.layer.mask?.animation(forKey: "rowGrowth") as? CASpringAnimation)
        #expect(abs((grow.fromValue as? CGFloat ?? 0) - contentBottom) < 0.01, "閉じていたときの中身の下の端から切り抜いていません")
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "開いたときに下の行を動かしていません")

        // 描かれる前の行は像を取れないため、描かれるのを待つ。
        try await waitUntil { harness.visibleCell(of: id)?.snapshotView(afterScreenUpdates: false) != nil }
        harness.viewController.toggleSpoiler(of: statuses[10], keeping: id)

        let cell = try #require(harness.visibleCell(of: id))
        #expect(abs(cell.bounds.height - height) < 0.5, "注意書きを閉じても行が縮んでいません")
        let mask = try #require(cell.subviews.lazy.compactMap { $0.layer.mask }.first { $0.animation(forKey: TimelineViewController.shrinkName) != nil }, "閉じたときに、なくなる本文の像を縮めていません")
        #expect(abs(mask.frame.minY - contentBottom) < 0.01, "閉じたあとの中身の下の端まで縮めていません")
    }

    /// 編集で本文が伸びた行も、その行の位置を保ち、下の行を元の位置から動かす。
    @Test func editedRowShiftsRowsBelow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "編集で伸びた本文。", count: 20) + "</p>")
        harness.setStatuses(statuses)

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "編集しても行が伸びていません")
        #expect(try abs(#require(harness.windowMinY(of: id)) - y) < 0.5, "編集した行が動きました")
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "下の行を動かしていません")
    }

    /// 上端が表示領域より上にある行が編集で伸びたら、中身全体を、伸びた分だけ下の、前の画面上の位置から動かす。
    /// 伸びた本文は、前の高さから切り抜きを広げる。切り抜かないと、足された本文が、動き始めに行の下端からはみ出して下の行に重なる。
    @Test func editedRowAboveTopSlidesItsContent() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 20
        harness.collectionView.layoutIfNeeded()
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "編集で伸びた本文。", count: 20) + "</p>")
        harness.setStatuses(statuses)
        harness.collectionView.layoutIfNeeded()

        let cell = try #require(harness.visibleCell(of: id))
        let grown = cell.bounds.height - height
        #expect(grown > 0, "編集しても行が伸びていません")
        let slides = (cell.contentView.layer.animationKeys() ?? []).compactMap { cell.contentView.layer.animation(forKey: $0) as? CABasicAnimation }
            .filter { $0.isAdditive && $0.keyPath == "position" }
            .compactMap { ($0.fromValue as? CGPoint)?.y }
        #expect(slides.count == 1 && abs((slides.first ?? 0) - grown) < 0.5, "中身を、伸びた分だけ下から動かしていません")
        let body = try #require(cell.contentView as? PostContentView).postBody
        #expect(body.subviews.contains { $0.layer.mask?.animation(forKey: TimelineViewController.partRevealName) != nil }, "伸びた本文を切り抜いていません")
    }

    /// 上端が表示領域より上にある行にリンクカードが現れたら、カードは動き始めから最後の位置に置き、下の端から切り抜いて現す。
    /// カードより上の本文は、伸びた分だけ下の、前の画面上の位置から動かす。本文が上へ退くのに合わせて、カードが現れる。
    @Test func cardAppearingInRowAboveTopIsRevealedFromItsBottom() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 20
        harness.collectionView.layoutIfNeeded()
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        let base = statuses[10]
        let card = PreviewCard(url: try #require(URL(string: "https://news.example/a")), title: "見出し", description: "説明", type: .link, providerName: "", image: nil, width: 0, height: 0, blurhash: nil)
        statuses[10] = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, card: card)
        harness.setStatuses(statuses)
        harness.collectionView.layoutIfNeeded()

        let cell = try #require(harness.visibleCell(of: id))
        let grown = cell.bounds.height - height
        #expect(grown > 0, "リンクカードが現れても行が伸びていません")
        let body = try #require(cell.contentView as? PostContentView).postBody
        let cardView = try #require(body.linkCard, "リンクカードが出ていません")
        #expect(abs(harness.initialOffsetY(of: cardView, in: cell)) < 0.5, "カードが、動き始めに\(harness.initialOffsetY(of: cardView, in: cell))ptずれています")
        let mask = try #require(cardView.layer.mask, "カードを切り抜いていません")
        #expect(mask.animation(forKey: TimelineViewController.partRevealName) != nil)
        #expect(mask.anchorPoint.y == 1, "カードを下の端から現していません")
        let text = try #require(body.subviews.first { $0 is LinkLabel }, "本文がありません")
        #expect(abs(harness.initialOffsetY(of: text, in: cell) - grown) < 0.5, "本文が、前の位置から動いていません（\(harness.initialOffsetY(of: text, in: cell))pt、伸びは\(grown)pt）")
    }

    /// 切り抜きを広げている途中に同じ行がまた伸びたら、切り抜きの行き先を新しい高さへ動かし直す。
    /// 動かし直さないと、切り抜きは前の高さまでしか広がらず、足された分が、切り抜きを外すコマで一度に現れる。
    @Test func growingAgainRetargetsPartReveal() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 20
        harness.collectionView.layoutIfNeeded()

        for count in [10, 30] {
            statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "編集で伸びた本文。", count: count) + "</p>")
            harness.setStatuses(statuses)
            harness.collectionView.layoutIfNeeded()
        }

        let body = try #require(harness.visibleCell(of: id)?.contentView as? PostContentView).postBody
        let text = try #require(body.subviews.first { $0 is LinkLabel }, "本文がありません")
        let grow = try #require(text.layer.mask?.animation(forKey: TimelineViewController.partRevealName) as? CASpringAnimation, "伸びた本文を切り抜いていません")
        #expect(abs((grow.toValue as? CGFloat ?? 0) - text.bounds.height) < 0.5, "切り抜きの行き先が、今の高さになっていません")
    }

    /// 編集で本文にリンクが足された見えている投稿は、描き直したあとの中身で、カードを取り直す投稿として報告する。
    /// 描き直す前の中身で報告すると、リンクがないので報告から漏れ、次にスクロールするまで取り直さない。
    @Test func editedRowWithNewLinkIsReportedAsUnsettled() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        harness.scroll(toFraction: 0)
        var reported: [Status.ID] = []
        harness.viewController.onVisibleUnsettledStatusesChange = { reported = $0.map(\.id) }

        statuses[2] = replacing(statuses[2], content: #"<p><a href="https://news.example/article">news.example/article</a></p>"#)
        harness.setStatuses(statuses)

        #expect(reported.contains(statuses[2].id), "リンクが足された投稿を、カードを取り直す投稿として報告していません")
    }

    private func textLabel(in harness: TimelineHarness, of id: TimelineViewController.ItemID) throws -> EmojiLabel {
        let body = try #require(harness.visibleCell(of: id)?.contentView as? PostContentView).postBody
        return try #require(body.subviews.lazy.compactMap { $0 as? EmojiLabel }.first, "本文がありません")
    }

    /// 編集で本文の途中が削られたら、残った文字を前の位置から動かし、削られた文字は前の位置で薄くして消す。縮む前の行の像は重ねない。
    /// 像は、なくなる中身が行の末尾にあるものとして下の端から縮めるので、重ねると、動いている文字と像の中の文字が食い違う。
    @Test func removingTextInEditFadesRemovedCharacters() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = replacing(statuses[10], content: "<p>先頭の行</p><p>削る行1</p><p>削る行2</p><p>末尾の行</p>")
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .centeredVertically)
        harness.collectionView.layoutIfNeeded()

        statuses[10] = replacing(statuses[10], content: "<p>先頭の行</p><p>末尾の行</p>")
        harness.setStatuses(statuses)
        harness.collectionView.layoutIfNeeded()

        let label = try textLabel(in: harness, of: id)
        #expect(label.emojiArrival?.isRunning == true, "残った文字を動かしていません")
        let fading = (label.layer.sublayers ?? []).flatMap { $0.sublayers ?? [] }.filter { $0.animation(forKey: "fadeOut") != nil }
        #expect(!fading.isEmpty, "削られた文字を薄くしていません")
        let cell = try #require(harness.visibleCell(of: id))
        #expect(!cell.subviews.contains { $0.layer.mask?.animation(forKey: TimelineViewController.shrinkName) != nil }, "縮む前の行の像を重ねています")
    }

    /// 新着と一緒に届いた編集では、行を動かさずに替えるので、本文の文字も動かさない。
    /// 文字だけを動かすと、行は一度に伸びるのに中身が遅れて動き、伸びた場所が空いて見える。
    @Test func editArrivingWithNewRowDoesNotAnimateText() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .centeredVertically)
        harness.collectionView.layoutIfNeeded()
        let height = try #require(harness.visibleCell(of: id)?.bounds.height)

        statuses[10] = replacing(statuses[10], content: "<p>" + String(repeating: "編集で伸びた本文。", count: 20) + "</p>")
        harness.setStatuses(StatusFactory.make(count: 1, startingAt: 1_100) + statuses)
        harness.collectionView.layoutIfNeeded()

        #expect(try #require(harness.visibleCell(of: id)?.bounds.height) > height, "編集しても行が伸びていません")
        #expect(try textLabel(in: harness, of: id).emojiArrival?.isRunning != true, "行を動かさないのに、本文の文字を動かしています")
    }
}
