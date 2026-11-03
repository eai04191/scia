import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 並びの画面で、「その他」の境目の前と後ろを2つの節に分けて出す。
@MainActor
struct MenuLayoutSectionTests {
    /// 境目は行として出さず、境目の前と後ろの項目を、見出しを付けた2つの節に並べる。
    @Test func splitsRowsAtMoreBoundaryIntoTitledSections() throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }

        #expect(screen.headerTitle(ofSection: 0) == "＋のメニュー")
        #expect(screen.headerTitle(ofSection: 1) == "ツールバー")
        let more = try #require(ComposeToolItem.defaultLayout.elements.firstIndex(of: .more))
        #expect(screen.rowTitles(inSection: 0) == ComposeToolItem.defaultLayout.elements[..<more].map(Self.title(of:)))
        #expect(screen.rowTitles(inSection: 1) == ComposeToolItem.defaultLayout.elements[(more + 1)...].map(Self.title(of:)))
    }

    /// 節をまたいで動かした項目は、保存する並びで境目の反対側に入る。
    @Test func movingRowAcrossSectionsMovesItAcrossMoreBoundary() throws {
        var saved: MenuLayout<ComposeToolItem>?
        let screen = try Screen(layout: MenuLayout(elements: [.item(.spoiler, isVisible: true), .more, .item(.media, isVisible: true)])) { saved = $0 }
        defer { screen.close() }
        let spoiler = try #require(screen.indexPath(ofRowTitled: "注意書き"))
        #expect(spoiler.section == 0)

        // 並びに書かなかった項目は既定の位置に差し込まれるため、動かす先はメディアの行の位置から決める。
        let media = try #require(screen.indexPath(ofRowTitled: "メディアを添付"))
        #expect(media.section == 1)

        screen.move(from: spoiler, to: IndexPath(item: media.item + 1, section: 1))

        let elements = try #require(saved?.elements)
        let more = try #require(elements.firstIndex(of: .more))
        let moved = try #require(elements.firstIndex(of: .item(.spoiler, isVisible: true)))
        #expect(moved > more)
        #expect(elements[more...].firstIndex(of: .item(.media, isVisible: true)).map { $0 < moved } == true)
    }

    /// 項目のない節には「なし」の行を置き、そこへ動かした項目は、その節に入る。空の節には指を離せる場所がないため。
    @Test func emptySectionAcceptsMovedRow() async throws {
        var saved: MenuLayout<ComposeToolItem>?
        let screen = try Screen(layout: MenuLayout(elements: ComposeToolItem.allCases.map { .item($0, isVisible: true) } + [.more])) { saved = $0 }
        defer { screen.close() }
        #expect(screen.rowTitles(inSection: 1) == ["なし"])
        let first = try #require(screen.rowTitles(inSection: 0).first ?? nil)

        screen.move(from: IndexPath(item: 0, section: 0), to: IndexPath(item: 0, section: 1))

        #expect(saved?.elements.last == .item(try #require(ComposeToolItem.allCases.first), isVisible: true))
        try await waitUntil {
            screen.window.layoutIfNeeded()
            return screen.rowTitles(inSection: 1) == [first]
        }
    }

    private static func title(of element: MenuLayout<ComposeToolItem>.Element) -> String? {
        if case .item(let item, _) = element { item.title } else { nil }
    }

    /// 並びの画面を、すべての行が見える高さの窓に出す。
    @MainActor
    private struct Screen {
        let window: UIWindow
        let collectionView: UICollectionView

        init(layout: MenuLayout<ComposeToolItem>, onChange: @escaping (MenuLayout<ComposeToolItem>) -> Void = { _ in }) throws {
            let controller = MenuLayoutViewController<ComposeToolItem>(
                layout: layout,
                image: { _ in nil },
                imageRevision: 0,
                options: [],
                actions: [],
                itemDeletion: nil,
                onChange: onChange
            )
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 2400)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            collectionView = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func headerTitle(ofSection section: Int) -> String? {
            let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
            return ((header as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text
        }

        /// 区切り線の行はnilにする。
        func rowTitles(inSection section: Int) -> [String?] {
            (0..<collectionView.numberOfItems(inSection: section)).map { item in
                let cell = collectionView.cellForItem(at: IndexPath(item: item, section: section))
                return ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text
            }
        }

        func indexPath(ofRowTitled title: String) -> IndexPath? {
            for section in 0..<2 {
                if let item = rowTitles(inSection: section).firstIndex(of: title) {
                    return IndexPath(item: item, section: section)
                }
            }
            return nil
        }

        /// つまみで動かして離したときと同じく、data sourceに並べ替えを伝える。
        func move(from source: IndexPath, to destination: IndexPath) {
            collectionView.dataSource?.collectionView?(collectionView, moveItemAt: source, to: destination)
        }
    }
}
