import SciaCore
import SciaTesting
import SwiftUI
import Testing
import UIKit
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct AppearanceValueRowTests {
    nonisolated private static let groups = AppearanceCatalog.groups + NotificationAppearanceCatalog.groups

    /// 値を変えて変更ありのインジケーターが出ても、行の高さは変わらない。変わると、押されている状態のステッパーが指の下から動き、続けて選択すると行を選択したことになるため。
    /// 名前がどの幅で折り返しても変わらないよう、行の幅を少しずつ変えて、すべての項目で比べる。
    @Test(arguments: groups.indices) func modifiedMarkKeepsRowHeight(group: Int) throws {
        let unchanged = AppSettings(defaults: TestScratch.defaults("AppearanceValueRowTests.unchanged"))
        let changed = AppSettings(defaults: TestScratch.defaults("AppearanceValueRowTests.changed"))
        for item in Self.groups.flatMap(\.values) {
            let raised = item.defaultValue + item.step
            changed.setValue(item.range.contains(raised) ? raised : item.defaultValue - item.step, for: item)
            try #require(changed.isModified(item))
        }
        let widths = Array(stride(from: CGFloat(280), through: 400, by: 2))
        for item in Self.groups[group].values {
            #expect(heights(of: item, settings: changed, widths: widths) == heights(of: item, settings: unchanged, widths: widths), "\(item.title)")
        }
    }

    private func heights(of item: AppearanceValue, settings: AppSettings, widths: [CGFloat]) -> [CGFloat] {
        let host = UIHostingController(rootView: AppearanceValueRow(item: item, settings: settings, isFocused: false, onFocus: {}, onToggleFocus: {}))
        return widths.map { host.sizeThatFits(in: CGSize(width: $0, height: .greatestFiniteMagnitude)).height }
    }
}
