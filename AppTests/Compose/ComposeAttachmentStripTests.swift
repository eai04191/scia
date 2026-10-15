import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄のサムネイルの列を、ドラッグできない人も並べ替えられる。
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
        (0..<count).map { _ in ComposeAttachmentStrip.Item(attachment: DraftAttachment(state: .uploading), local: nil, status: .uploading) }
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
        #expect(cells[0].accessibilityCustomActions?.map(\.name) == ["後ろへ移動"])
        #expect(cells[1].accessibilityCustomActions?.map(\.name) == ["前へ移動", "後ろへ移動"])
        #expect(cells[2].accessibilityCustomActions?.map(\.name) == ["前へ移動"])

        let moveBack = try #require(cells[2].accessibilityCustomActions?.first)
        _ = moveBack.actionHandler?(moveBack)
        #expect(moves.map(\.0) == [items[2].attachment.id])
        #expect(moves.map(\.1) == [1])
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
        #expect(first.accessibilityCustomActions?.map(\.name) == ["後ろへ移動"])
        #expect(strip.tile(for: items[1].attachment.id) != nil)
    }
}
