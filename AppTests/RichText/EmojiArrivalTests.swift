import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// カスタム絵文字の画像が、空けていた場所に後から届くときの見え方。
@Suite(.scratch)
@MainActor
struct EmojiArrivalTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        let url = try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        return CustomEmoji(shortcode: shortcode, url: url, staticUrl: url)
    }

    /// 横長の絵文字の画像。空けていた正方形より幅が広いので、届くと同じ行のあとの文字がずれる。
    private func widePNG() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 10)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        }.pngData())
    }

    /// 空けていた場所に絵文字の画像が入ったら、ラベルを1コマで描き替えず、あとの文字を前の位置から新しい位置へ動かし、
    /// 絵文字はその場で薄い状態から濃くする。動いている間は、ラベル自身の描画を隠す。同じ中身を入れ直したときは、動かさない。
    @Test func labelMovesTextWhenEmojiArrives() async throws {
        let blobcat = try emoji("blobcat")
        let png = try widePNG()
        let store = EmojiImageStore { _ in png }
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        let text = RichText.plain("前 :blobcat: 後ろの文字", emojis: [blobcat])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let label = EmojiLabel()
        label.numberOfLines = 0
        label.emojiArrivalDuration = { 0.25 }
        label.frame = CGRect(x: 0, y: 100, width: 300, height: 60)
        window.addSubview(label)
        let clock = LayerClock(freezing: label.layer)

        let placeholder = renderer.render(text)
        label.attributedText = placeholder
        label.layoutIfNeeded()
        label.attributedText = placeholder
        label.layoutIfNeeded()
        #expect(label.emojiArrival?.isRunning != true)

        try await waitUntil { store.image(for: blobcat.staticUrl) != nil }
        label.attributedText = renderer.render(text)
        label.layoutIfNeeded()

        let arrival = try #require(label.emojiArrival)
        #expect(arrival.isRunning)
        #expect(label.layer.contentsRect == .zero, "動いている間に、ラベル自身の描画を隠していません")
        let pieces = label.layer.sublayers?.last?.sublayers ?? []
        #expect(pieces.contains { $0.animation(forKey: "move") != nil }, "あとの文字を動かしていません")
        #expect(pieces.contains { $0.animation(forKey: "fadeIn") != nil }, "絵文字を薄い状態から濃くしていません")
        // 行数を限らないラベルでは、像をラベルの枠で切らない。折り返しが減ると、前の最後の行から上がる文字が枠の外から動き始めるため。
        #expect(label.layer.sublayers?.last?.masksToBounds == false)

        // 動いている途中に、動く絵文字のアニメーション版が届いて層が出し直されても、隠したままにする。
        let animated = CALayer()
        label.layer.insertSublayer(animated, at: 0)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        #expect(animated.isHidden, "動いている途中に出し直された層を隠していません")

        try await clock.advance(by: 0.3)
        #expect(!animated.isHidden)
        #expect(!arrival.isRunning)
        #expect(label.layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 動いている途中に、使い回された行で別の文字列に替わったら、前の文字列の像を残さない。
    @Test func reuseDropsEmojiArrival() async throws {
        let blobcat = try emoji("blobcat")
        let png = try widePNG()
        let store = EmojiImageStore { _ in png }
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: store, language: "ja")
        let text = RichText.plain("前 :blobcat: 後ろの文字", emojis: [blobcat])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let label = EmojiLabel()
        label.emojiArrivalDuration = { 0.25 }
        label.frame = CGRect(x: 0, y: 100, width: 300, height: 60)
        window.addSubview(label)
        _ = LayerClock(freezing: label.layer)
        label.attributedText = renderer.render(text)
        label.layoutIfNeeded()
        try await waitUntil { store.image(for: blobcat.staticUrl) != nil }
        label.attributedText = renderer.render(text)
        label.layoutIfNeeded()
        let arrival = try #require(label.emojiArrival)
        #expect(arrival.isRunning)

        label.attributedText = NSAttributedString(string: "別の投稿")

        #expect(!arrival.isRunning)
        #expect(label.layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 文字は、同じ行に並び、同じだけ動く、続いた文字のまとまりで動かす。次の行へ移る文字は、行をまたいで動く。
    /// 新しく入った絵文字は、動かさずに薄い状態から濃くする。
    @Test func piecesFollowLines() {
        typealias Placement = EmojiArrivalTransition.Placement
        // 「A[絵文字]BC」で、絵文字が広がり、Cが次の行の頭へ移る。
        let start: [Int: Placement] = [
            0: Placement(frame: CGRect(x: 0, y: 0, width: 10, height: 20), opacity: 1),
            1: Placement(frame: CGRect(x: 10, y: 0, width: 20, height: 20), opacity: 0),
            2: Placement(frame: CGRect(x: 30, y: 0, width: 10, height: 20), opacity: 1),
            3: Placement(frame: CGRect(x: 40, y: 0, width: 10, height: 20), opacity: 1),
        ]
        let final: [Int: CGRect] = [
            0: CGRect(x: 0, y: 0, width: 10, height: 20),
            1: CGRect(x: 10, y: 0, width: 30, height: 20),
            2: CGRect(x: 40, y: 0, width: 10, height: 20),
            3: CGRect(x: 0, y: 20, width: 10, height: 20),
        ]

        let pieces = EmojiArrivalTransition.pieces(start: start, final: final)

        #expect(pieces.map(\.indices) == [[0], [1], [2], [3]])
        #expect(pieces[0].offset == .zero)
        #expect(pieces[1].startOpacity == 0)
        #expect(pieces[2].offset == CGPoint(x: 10, y: 0))
        #expect(pieces[3].offset == CGPoint(x: -40, y: 20))
    }

    /// 絵文字が届いて見えている行の折り返しが増えたら、下の行を1コマで下げず、元の位置から新しい位置へ動かす。上の行は動かさない。
    /// 行のセルは入れ替えない。入れ替えると、セルの中で続いている文字の動きが止まるため。
    @Test func visibleRowGrowthShiftsRowsBelow() async throws {
        let wide = try (1...6).map { try emoji("wide\($0)") }
        let png = try widePNG()
        let gate = Gate()
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let harness = try TimelineHarness(emojiImages: store)
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let base = statuses[10]
        statuses[10] = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>" + wide.map { ":\($0.shortcode):" }.joined(separator: " 文字 ") + "</p>",
            spoilerText: "",
            url: nil,
            emojis: wide
        )
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(base.id)
        let above = TimelineViewController.ItemID.status(statuses[9].id)
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: id, at: .centeredVertically)
        let cell = try #require(harness.visibleCell(of: id))
        let belowCell = try #require(harness.visibleCell(of: below))
        let aboveCell = try #require(harness.visibleCell(of: above))
        let height = cell.frame.height
        let belowY = try #require(harness.windowMinY(of: below))

        gate.open()
        try await waitUntil { cell.frame.height > height }

        #expect(harness.visibleCell(of: id) === cell, "行のセルを入れ替えました")
        let grown = cell.frame.height - height
        #expect(try abs(#require(harness.windowMinY(of: below)) - (belowY + grown)) < 0.5)
        #expect(belowCell.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true, "下の行を動かしていません")
        #expect(aboveCell.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } != true, "上の行を動かしました")
        // 下がる行は、伸びた行より手前に描く。伸びた行のセルは一度に高くなり、その背景が下がってくる途中の行を隠すため。
        let order = harness.collectionView.subviews
        #expect(try #require(order.firstIndex(of: belowCell)) > #require(order.firstIndex(of: cell)), "下がる行を伸びた行より手前に描いていません")
        #expect(belowCell.layer.zPosition == 0, "バーの下のぼかしより手前に出ないよう、zPositionは変えません")
        // 区切り線は行のセルとは別のビューなので、一緒に動かす。動かさないと、伸びた行の下の線だけが1コマで下がる。
        let separators = harness.collectionView.subviews.filter { !($0 is UICollectionViewCell) && $0.bounds.height <= 2 }
        #expect(separators.contains { $0.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true }, "区切り線を動かしていません")
    }

    /// `index`番目の行に、届くと折り返しが増える横長の絵文字を並べた一覧。絵文字は`gate`を開けるまで届かない。
    private func widePostHarness(at index: Int) throws -> (harness: TimelineHarness, gate: Gate, statuses: [Status]) {
        let wide = try (1...6).map { try emoji("wide\($0)") }
        let png = try widePNG()
        let gate = Gate()
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let harness = try TimelineHarness(emojiImages: store)
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let base = statuses[index]
        statuses[index] = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>" + wide.map { ":\($0.shortcode):" }.joined(separator: " 文字 ") + "</p>",
            spoilerText: "",
            url: nil,
            emojis: wide
        )
        harness.setStatuses(statuses)
        return (harness, gate, statuses)
    }

    private func hasRowShift(_ cell: UICollectionViewCell) -> Bool {
        cell.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true
    }

    /// ナビゲーションバーの裏に隠れた行が伸び、読んでいる位置を保つためにスクロール位置を補正したときは、見えている行を動かさない。
    @Test func hiddenRowGrowthDoesNotShiftVisibleRows() async throws {
        let (harness, gate, statuses) = try widePostHarness(at: 10)
        defer { harness.tearDown() }
        let hidden = TimelineViewController.ItemID.status(statuses[10].id)
        let reading = TimelineViewController.ItemID.status(statuses[11].id)
        try harness.scroll(to: reading, at: .top)
        let hiddenCell = try #require(harness.visibleCell(of: hidden), "隠れた行のセルがありません")
        let height = hiddenCell.frame.height
        let readingCell = try #require(harness.visibleCell(of: reading))
        let y = try #require(harness.windowMinY(of: reading))

        gate.open()
        try await waitUntil { hiddenCell.frame.height > height }

        #expect(harness.windowMinY(of: reading) == y)
        #expect(!hasRowShift(readingCell), "位置を保った行を動かしました")
    }

    /// 表示領域の上端をまたぐ行が同じ絵文字を使っていても、その行の高さが変わらなければ、見えている行が伸びた分は下の行ごと動かす。
    @Test func unchangedRowAcrossTopDoesNotStopShifting() async throws {
        let (harness, gate, statuses) = try widePostHarness(at: 12)
        defer { harness.tearDown() }
        // 上端をまたぐ行にも同じ絵文字を1つだけ置く。届いても折り返しは変わらない。
        let across = statuses[10]
        let small = Status(id: across.id, createdAt: across.createdAt, account: across.account, content: "<p>:wide1:</p>", spoilerText: "", url: nil, emojis: [try emoji("wide1")])
        var updated = statuses
        updated[10] = small
        harness.setStatuses(updated)
        let acrossID = TimelineViewController.ItemID.status(across.id)
        let growing = TimelineViewController.ItemID.status(statuses[12].id)
        let below = TimelineViewController.ItemID.status(statuses[13].id)
        try harness.scroll(to: acrossID, at: .top)
        harness.collectionView.contentOffset.y += 10
        harness.collectionView.layoutIfNeeded()
        let growingCell = try #require(harness.visibleCell(of: growing))
        let belowCell = try #require(harness.visibleCell(of: below))
        let height = growingCell.frame.height

        gate.open()
        try await waitUntil { growingCell.frame.height > height }

        #expect(hasRowShift(belowCell), "上端をまたぐ行が変わらないのに、下の行を動かしませんでした")
    }

    /// 絵文字が届いて、上端が表示領域より上にある行の折り返しが増えても、その行の画面上の位置は動かない。
    /// 下の行は、1コマで下げず、元の位置から新しい位置へ動かす。
    @Test func emojiArrivalKeepsRowAboveTop() async throws {
        let wide = try (1...6).map { try emoji("wide\($0)") }
        let png = try widePNG()
        let gate = Gate()
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let harness = try TimelineHarness(emojiImages: store)
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let base = statuses[10]
        statuses[10] = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>" + wide.map { ":\($0.shortcode):" }.joined(separator: " 文字 ") + "</p>",
            spoilerText: "",
            url: nil,
            emojis: wide
        )
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(base.id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 10
        harness.collectionView.layoutIfNeeded()
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.frame.height)
        let belowCell = try #require(harness.visibleCell(of: .status(statuses[11].id)))

        gate.open()
        try await waitUntil { (try? #require(harness.visibleCell(of: id)?.frame.height)).map { $0 > height } ?? false }

        #expect(harness.windowMinY(of: id) == y)
        #expect(hasRowShift(belowCell), "下の行を動かしていません")
    }
}
