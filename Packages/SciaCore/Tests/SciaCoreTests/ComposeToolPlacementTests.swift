import Testing
@testable import SciaCore

/// 投稿欄の部品を足す項目を、ボタンの行と＋のメニューに振り分ける。
struct ComposeToolPlacementTests {
    private func placement(_ elements: [MenuLayout<ComposeToolItem>.Element], available: Double, addButtonWidth: Double = 40) -> ComposeToolPlacement {
        // 公開範囲と展開は、並びに書かなければ既定どおり行に差し込まれるので、隠しておく。
        ComposeToolPlacement(layout: MenuLayout(elements: elements + [.item(.visibility, isVisible: false), .item(.expand, isVisible: false), .item(.linkTitle, isVisible: false), .item(.customize, isVisible: false)]), available: available, addButtonWidth: addButtonWidth, width: { _ in 40 })
    }

    /// 既定では、注意書き、リンクにタイトルを付ける、カスタマイズは＋に入れ、ボタンの行は「＋ 公開範囲 添付 展開」にする。
    @Test func defaultShowsExistingButtonsInRowAndSpoilerInMenu() {
        let placement = ComposeToolPlacement(layout: ComposeToolItem.defaultLayout, available: 200, addButtonWidth: 40, width: { _ in 40 })

        #expect(placement.row == [.visibility, .media, .expand])
        #expect(placement.menu == [[.customize], [.linkTitle, .spoiler]])
        #expect(placement.showsAddButton)
    }

    /// ＋に何も入れず、行に全部入るなら、＋を出さない。
    @Test func hidesAddButtonWhenEverythingFitsInRow() {
        let placement = placement([.more, .item(.media, isVisible: true), .item(.spoiler, isVisible: true)], available: 80)

        #expect(placement.row == [.media, .spoiler])
        #expect(placement.menu.isEmpty)
        #expect(!placement.showsAddButton)
    }

    /// 行に入りきらない項目は、並びの後ろから＋のメニューへ回す。＋を出すので、その幅も差し引く。
    @Test func movesOverflowIntoMenu() {
        let placement = placement([.more, .item(.media, isVisible: true), .item(.spoiler, isVisible: true)], available: 79, addButtonWidth: 20)

        #expect(placement.row == [.media])
        #expect(placement.menu == [[.spoiler]])
    }

    /// 行に1つも入らなければ、全部を＋に入れる。回した項目は、＋に元からある項目の後ろ（＋にいちばん近いところ）に続ける。
    @Test func overflowGroupComesAfterMenuItems() {
        let placement = placement([.item(.spoiler, isVisible: true), .more, .item(.media, isVisible: true)], available: 60)

        #expect(placement.row.isEmpty)
        #expect(placement.menu == [[.spoiler], [.media]])
    }

    /// 非表示にした項目は、行にも＋にも出さない。
    @Test func hiddenItemsAppearNowhere() {
        let placement = placement([.item(.spoiler, isVisible: true), .more, .item(.media, isVisible: false)], available: 200)

        #expect(placement.row.isEmpty)
        #expect(placement.menu == [[.spoiler]])
    }
}
