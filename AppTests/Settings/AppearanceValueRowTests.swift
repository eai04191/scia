import SciaCore
import SciaTesting
import SwiftUI
import Testing
import UIKit
@testable import Scia

@Suite(.scratch)
@MainActor
struct AppearanceValueRowTests {
    /// 値を変えて変更ありの印が出ても、行の高さは変わらない。変わると、押しているステッパーが指の下から動き、続けて押すと行のタップになるため。
    /// 名前がどの幅で折り返しても変わらないよう、行の幅を少しずつ変えて、すべての項目で比べる。
    @Test func modifiedMarkKeepsRowHeight() throws {
        let unchanged = AppSettings(defaults: TestScratch.defaults("AppearanceValueRowTests.unchanged"))
        let changed = AppSettings(defaults: TestScratch.defaults("AppearanceValueRowTests.changed"))
        let items = AppearanceCatalog.values + NotificationAppearanceCatalog.values
        for item in items {
            let raised = item.defaultValue + item.step
            changed.setValue(item.range.contains(raised) ? raised : item.defaultValue - item.step, for: item)
            try #require(changed.isModified(item))
        }
        let widths = Array(stride(from: CGFloat(280), through: 400, by: 2))
        for item in items {
            #expect(heights(of: item, settings: changed, widths: widths) == heights(of: item, settings: unchanged, widths: widths), "\(item.title)")
        }
    }

    private func heights(of item: AppearanceValue, settings: AppSettings, widths: [CGFloat]) -> [CGFloat] {
        let host = UIHostingController(rootView: AppearanceValueRow(item: item, settings: settings, isFocused: false, onFocus: {}, onToggleFocus: {}))
        return widths.map { host.sizeThatFits(in: CGSize(width: $0, height: .greatestFiniteMagnitude)).height }
    }
}
