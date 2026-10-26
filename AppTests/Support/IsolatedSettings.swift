import Foundation
import SciaTesting
import Testing
import SciaCore
@testable import Scia

extension AppSettings {
    /// テストごとに空の保存先を持つ設定。テストを走らせるアプリは端末のアプリと同じ保存先を読むため、
    /// 既定の`AppDependencies.settings`を使うと、端末で変えた表示の設定によってテストの結果が変わる。
    @MainActor
    static func isolated() -> AppSettings {
        AppSettings(defaults: TestScratch.defaults("IsolatedSettings"))
    }
}
