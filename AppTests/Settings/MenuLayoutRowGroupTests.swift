import SciaCore
import Testing
@testable import Scia

/// 並びの画面で、横並びの区切り線の下の、メニューで横に並ぶ項目をインデントする位置。
@MainActor
@Suite(.failureState)
struct MenuLayoutRowGroupTests {
    private typealias Controller = MenuLayoutViewController<StatusMenuItem>

    /// 表示する項目の先頭から3個までをインデントし、4個目からはインデントしない。
    @Test func indentsUpToCapacity() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .item(.reply, isVisible: true), .rowSeparator(.medium),
            .item(.favourite, isVisible: true), .item(.bookmark, isVisible: true), .item(.quote, isVisible: true), .item(.reblog, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements) == [2, 3, 4])
    }

    /// 隠した項目は数えずに、その間に挟まるものはインデントしてグループを途切れさせない。
    @Test func hiddenItemsDoNotUseSlots() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .rowSeparator(.medium), .item(.favourite, isVisible: true), .item(.bookmark, isVisible: false), .item(.quote, isVisible: true), .item(.reblog, isVisible: true), .item(.reply, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements) == [1, 2, 3, 4])
    }

    /// 区切り線か「その他」の境目で、グループが終わる。
    @Test func groupEndsAtSeparatorOrMore() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .rowSeparator(.medium), .item(.favourite, isVisible: true), .separator, .item(.bookmark, isVisible: true),
            .rowSeparator(.medium), .item(.quote, isVisible: true), .more, .item(.reblog, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements) == [1, 5])
    }

    /// アイコンのみの横並びは、4個までをインデントする。
    @Test func smallRowIndentsFour() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .rowSeparator(.small),
            .item(.favourite, isVisible: true), .item(.bookmark, isVisible: true), .item(.quote, isVisible: true), .item(.reblog, isVisible: true), .item(.reply, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements) == [1, 2, 3, 4])
    }

    /// 投稿欄の並びでは、＋のメニューのセクションの横並びだけをインデントする。ツールバーのセクションでは横並びの区切り線が効かないため。
    @Test func composeToolbarSectionIsNotIndented() {
        let elements: [MenuLayout<ComposeToolItem>.Element] = [
            .rowSeparator(.medium), .item(.spoiler, isVisible: true), .more, .rowSeparator(.medium), .item(.media, isVisible: true),
        ]
        #expect(MenuLayoutViewController<ComposeToolItem>.rowGroupIndices(in: elements) == [1])
    }
}
