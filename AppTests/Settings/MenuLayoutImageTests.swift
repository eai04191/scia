import SciaCore
import Testing
import UIKit
@testable import Scia

/// 並びの画面で、項目の記号の代わりに出す画像。タブに置いたプロフィールのアイコンは、画面を開いたあとに届くことがある。
@MainActor
@Suite(.failureState)
struct MenuLayoutImageTests {
    private static let bob = TabItem.profile(accountID: "2", acct: "bob")

    /// 画像が変わったと知らされたら、出している行を描き直す。
    @Test func redrawsRowsWhenImageChanges() throws {
        let avatar = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var given: UIImage?
        let controller = MenuLayoutViewController<TabItem>(
            layout: MenuLayout(elements: [.item(.home, isVisible: true), .item(Self.bob, isVisible: true), .more]),
            image: { $0 == Self.bob ? given : nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: nil
        ) { _ in }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #expect(try Self.image(ofRowTitled: "@bob", in: controller)?.isSymbolImage == true)

        given = avatar
        controller.setImageRevision(1)
        window.layoutIfNeeded()

        #expect(try Self.image(ofRowTitled: "@bob", in: controller)?.isSymbolImage == false)
    }

    /// 並びに書かなかった項目は既定の位置に差し込まれるため、行は名前で探す。
    private static func image(ofRowTitled title: String, in controller: UIViewController) throws -> UIImage? {
        let collectionView = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let contents = collectionView.visibleCells.compactMap { ($0 as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration }
        return try #require(contents.first { $0.text == title }).image
    }
}
