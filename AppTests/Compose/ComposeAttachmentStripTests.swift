import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄のサムネイルの列を、ドラッグできない人も並べ替えたり外したりできる。
@MainActor
@Suite(.serialized)
struct ComposeAttachmentStripTests {
    private let window: UIWindow
    private let strip = ComposeAttachmentStrip()

    init() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 200)
        strip.frame = CGRect(x: 0, y: 0, width: 393, height: ComposeAttachmentStrip.itemSize)
        window.addSubview(strip)
        window.makeKeyAndVisible()
    }

    private func items(_ count: Int) -> [ComposeAttachmentStrip.Item] {
        (0..<count).map { _ in ComposeAttachmentStrip.Item(attachment: DraftAttachment(state: .uploading), local: nil, status: .uploading, isSensitive: false) }
    }

    private func cells() -> [UICollectionViewCell] {
        let collectionView = strip.subviews.compactMap { $0 as? UICollectionView }.first
        return (collectionView?.visibleCells ?? []).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// 端のサムネイルには動かせない向きの操作を出さず、選んだ操作は移す先の位置を渡す。
    @Test func moveActionsMoveAttachmentByOne() throws {
        defer { window.isHidden = true }
        let items = items(3)
        var moves: [(DraftAttachment.ID, Int)] = []
        strip.onMove = { moves.append(($0, $1)) }
        strip.update(items)
        strip.layoutIfNeeded()

        let cells = cells()
        try #require(cells.count == 3)
        #expect(cells[0].accessibilityCustomActions?.map(\.name) == ["後ろへ移動", "末尾へ移動", "削除"])
        #expect(cells[1].accessibilityCustomActions?.map(\.name) == ["前へ移動", "後ろへ移動", "削除"])
        #expect(cells[2].accessibilityCustomActions?.map(\.name) == ["先頭へ移動", "前へ移動", "削除"])

        let moveForward = try #require(cells[2].accessibilityCustomActions?[1])
        _ = moveForward.actionHandler?(moveForward)
        #expect(moves.map(\.0) == [items[2].attachment.id])
        #expect(moves.map(\.1) == [1])
    }

    /// 先頭へ・末尾へは端まで一度に移す。前へ・後ろへと同じ移動になるときは出さない。
    @Test func moveActionsMoveAttachmentToEnds() throws {
        defer { window.isHidden = true }
        let items = items(4)
        var moves: [(DraftAttachment.ID, Int)] = []
        strip.onMove = { moves.append(($0, $1)) }
        strip.update(items)
        strip.layoutIfNeeded()

        let cells = cells()
        try #require(cells.count == 4)
        #expect(cells[1].accessibilityCustomActions?.map(\.name) == ["前へ移動", "後ろへ移動", "末尾へ移動", "削除"])
        #expect(cells[2].accessibilityCustomActions?.map(\.name) == ["先頭へ移動", "前へ移動", "後ろへ移動", "削除"])

        let toLast = try #require(cells[1].accessibilityCustomActions?.first { $0.name == "末尾へ移動" })
        _ = toLast.actionHandler?(toLast)
        let toFirst = try #require(cells[2].accessibilityCustomActions?.first { $0.name == "先頭へ移動" })
        _ = toFirst.actionHandler?(toFirst)
        #expect(moves.map(\.0) == [items[1].attachment.id, items[2].attachment.id])
        #expect(moves.map(\.1) == [3, 0])
    }

    /// 削除を選ぶと、その添付を外すよう知らせる。
    @Test func removeActionRemovesAttachment() throws {
        defer { window.isHidden = true }
        let items = items(2)
        var removed: [DraftAttachment.ID] = []
        strip.onRemove = { removed.append($0) }
        strip.update(items)
        strip.layoutIfNeeded()

        let remove = try #require(cells()[1].accessibilityCustomActions?.first { $0.name == "削除" })
        _ = remove.actionHandler?(remove)
        #expect(removed == [items[1].attachment.id])
    }

    /// 並べ替えた後に描き直すと、位置に合わせて操作も変わる。
    @Test func moveActionsFollowNewOrder() throws {
        defer { window.isHidden = true }
        let items = items(2)
        strip.update(items)
        strip.layoutIfNeeded()
        strip.update([items[1], items[0]])
        strip.layoutIfNeeded()

        let first = try #require(cells().first)
        #expect(first.accessibilityCustomActions?.map(\.name) == ["後ろへ移動", "削除"])
        #expect(strip.tile(for: items[1].attachment.id) != nil)
    }
}
