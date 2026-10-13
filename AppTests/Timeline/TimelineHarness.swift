import SciaCore
import Testing
import UIKit
@testable import Scia

/// TimelineViewControllerを実際のウィンドウに載せ、セルの画面上の位置を測るためのハーネス。
@MainActor
final class TimelineHarness {
    let viewController = TimelineViewController(emojiImages: .offline)
    private let window: UIWindow

    init(size: CGSize = CGSize(width: 393, height: 852)) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UINavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
    }

    var collectionView: UICollectionView { viewController.collectionView }

    /// 表示領域の`fraction`（0が先頭、1が末尾）の位置までスクロールし、セルを確定させる。
    func scroll(toFraction fraction: CGFloat) {
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let maxOffset = collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        collectionView.contentOffset.y = -inset.top + (maxOffset + inset.top) * fraction
        collectionView.layoutIfNeeded()
    }

    /// 投稿のセル上端の、ウィンドウ座標でのY位置。セルが表示されていなければnil。
    func windowMinY(of id: Status.ID) -> CGFloat? {
        guard let cell = visibleCell(of: id) else { return nil }
        return cell.convert(cell.bounds, to: window).minY
    }

    /// 表示中のセルに設定されている本文。セルが表示されていなければnil。
    func secondaryText(of id: Status.ID) -> String? {
        (visibleCell(of: id)?.contentConfiguration as? UIListContentConfiguration)?.secondaryAttributedText?.string
    }

    private func visibleCell(of id: Status.ID) -> UICollectionViewCell? {
        collectionView.layoutIfNeeded()
        return collectionView.visibleCells.first { cell in
            guard let indexPath = collectionView.indexPath(for: cell) else { return false }
            return viewController.itemIdentifier(at: indexPath) == id
        }
    }
}

/// 高さがばらつく投稿を、新しい順に生成する。
enum StatusFactory {
    private static let bodies = [
        "短い投稿",
        "二行くらいになる投稿です。タイムラインのセルの高さが揃わないようにするために、少し長めの文章を入れています。",
        "とても長い投稿。" + String(repeating: "ストリーミングで新着が流れてきても、読んでいる位置が動かないことを確かめる。", count: 6),
    ]

    static func make(count: Int, startingAt base: Int) -> [Status] {
        (0..<count).map { offset in
            let number = base - offset
            return Status(
                id: String(format: "%018d", number),
                createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
                account: Account(
                    id: "1",
                    username: "alice",
                    acct: "alice",
                    displayName: "Alice #\(number)",
                    avatar: URL(string: "https://example.social/avatars/alice.png")!
                ),
                content: bodies[number % bodies.count],
                spoilerText: "",
                url: nil
            )
        }
    }
}

extension EmojiImageStore {
    /// 画像を読みに行かず、すべて失敗として扱う。
    static var offline: EmojiImageStore {
        EmojiImageStore { _ in throw URLError(.notConnectedToInternet) }
    }
}
