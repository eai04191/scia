import SciaCore
import Testing

struct InAppBrowserHeightTests {
    /// 上に空ける長さを引くので、取れる高さが変わっても、上に見える量は同じになる。
    @Test func keepsSameSpaceAboveAcrossScreens() {
        let height = InAppBrowserHeight(spaceAbove: 200)
        #expect(800 - height.sheetHeight(available: 800, minimum: 120) == 700 - height.sheetHeight(available: 700, minimum: 120))
    }

    @Test(arguments: [(201.0, 200.0), (203.0, 204.0), (-10.0, 8.0), (4.0, 8.0)])
    func snapsToSteps(_ given: Double, _ expected: Double) {
        #expect(InAppBrowserHeight(spaceAbove: given).spaceAbove == expected)
    }

    /// 引ききれない長さは、伏せた高さで止める。
    @Test func stopsAtMinimumInShortWindows() {
        #expect(InAppBrowserHeight(spaceAbove: 400).sheetHeight(available: 300, minimum: 120) == 120)
    }

    /// 決められる範囲は、短いほうの端から伏せた高さになるところまで。長いほうに数で決めた端を持たない。
    @Test func selectableSpacesReachFromTopToMinimum() {
        let spaces = InAppBrowserHeight.selectableSpaces(available: 778, minimum: 120)
        #expect(spaces.first == 8)
        #expect(spaces.last == 656)
        #expect(zip(spaces, spaces.dropFirst()).allSatisfy { $1 - $0 == 4 })
        #expect(spaces.contains(InAppBrowserHeight.standard.spaceAbove))
    }

    @Test func clampsToSelectableRange() {
        #expect(InAppBrowserHeight(spaceAbove: 700).clamped(available: 778, minimum: 120) == InAppBrowserHeight(spaceAbove: 656))
        #expect(InAppBrowserHeight(spaceAbove: 200).clamped(available: 778, minimum: 120) == InAppBrowserHeight(spaceAbove: 200))
    }

    @Test func titleShowsSpaceAboveInPoints() {
        #expect(InAppBrowserHeight(spaceAbove: 324).title == "324pt")
    }
}
