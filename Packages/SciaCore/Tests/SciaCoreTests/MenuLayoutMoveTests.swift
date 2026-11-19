import Testing
@testable import SciaCore

/// 並びの画面で、ボタンやメニューで行を動かす先。
struct MenuLayoutMoveTests {
    /// 上下は1つずつ動かし、一番上と一番下は端へ動かす。
    @Test func movesWithinBounds() {
        #expect(MenuLayoutMove.up.destination(from: 2, count: 5) == 1)
        #expect(MenuLayoutMove.down.destination(from: 2, count: 5) == 3)
        #expect(MenuLayoutMove.toTop.destination(from: 2, count: 5) == 0)
        #expect(MenuLayoutMove.toBottom.destination(from: 2, count: 5) == 4)
    }

    /// 端にある行は、端の向きには動かない。押せないボタンと出さない項目を、これで決める。
    @Test func doesNotMovePastEnds() {
        #expect(MenuLayoutMove.up.destination(from: 0, count: 5) == nil)
        #expect(MenuLayoutMove.toTop.destination(from: 0, count: 5) == nil)
        #expect(MenuLayoutMove.down.destination(from: 4, count: 5) == nil)
        #expect(MenuLayoutMove.toBottom.destination(from: 4, count: 5) == nil)
        #expect(MenuLayoutMove.down.destination(from: 0, count: 1) == nil)
    }

    /// 並びの外の位置からは動かさない。
    @Test func ignoresIndexOutsideLayout() {
        #expect(MenuLayoutMove.up.destination(from: 5, count: 5) == nil)
        #expect(MenuLayoutMove.down.destination(from: -1, count: 5) == nil)
    }
}
