import SciaCore
import Testing
@testable import Scia

/// 並びの画面で、横並びの区切り線の下の、メニューで横に並ぶ項目を字下げする位置。
@MainActor
struct MenuLayoutRowGroupTests {
    private typealias Controller = MenuLayoutViewController<StatusMenuItem>

    /// 表示する項目の先頭から3個までを字下げし、4個目からは字下げしない。
    @Test func indentsUpToCapacity() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .item(.reply, isVisible: true), .rowSeparator,
            .item(.favourite, isVisible: true), .item(.bookmark, isVisible: true), .item(.quote, isVisible: true), .item(.reblog, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements, capacity: 3) == [2, 3, 4])
    }

    /// 隠した項目は数えずに、その間に挟まるものは字下げしてまとまりを途切れさせない。
    @Test func hiddenItemsDoNotUseSlots() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .rowSeparator, .item(.favourite, isVisible: true), .item(.bookmark, isVisible: false), .item(.quote, isVisible: true), .item(.reblog, isVisible: true), .item(.reply, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements, capacity: 3) == [1, 2, 3, 4])
    }

    /// 区切り線か「その他」の境目で、まとまりが終わる。
    @Test func groupEndsAtSeparatorOrMore() {
        let elements: [MenuLayout<StatusMenuItem>.Element] = [
            .rowSeparator, .item(.favourite, isVisible: true), .separator, .item(.bookmark, isVisible: true),
            .rowSeparator, .item(.quote, isVisible: true), .more, .item(.reblog, isVisible: true),
        ]
        #expect(Controller.rowGroupIndices(in: elements, capacity: 3) == [1, 5])
    }
}
