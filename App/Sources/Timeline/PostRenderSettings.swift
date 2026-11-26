import Observation
import SciaCore
import UIKit

/// リストごとに、投稿の描画に使う設定を解決して保持する。行の生成時には購読を作り直さない。
@MainActor
final class PostRenderSettings {
    let settings: AppSettings
    private var cached: Values?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func read() -> Values {
        if let cached { return cached }
        let values = withObservationTracking {
            Values(settings: settings)
        } onChange: { [weak self] in
            // AppSettingsはMainActorで変更する。通知はwillSetなので、この中では古い値を再読み込みせず、次の読み取りで解決する。
            MainActor.assumeIsolated { self?.cached = nil }
        }
        cached = values
        return values
    }

    /// UIFontは保持せず、文字サイズの差だけを保持する。Dynamic Typeの変更は、フォントを作るときのtraitで反映する。
    @MainActor
    final class Values {
        let appearance: AppearanceChoices
        let typography: PostTypography
        let rowMargins: NSDirectionalEdgeInsets
        private let numericValues: [String: Double]

        fileprivate init(settings: AppSettings) {
            appearance = settings.appearance
            typography = PostTypography(settings: settings)
            rowMargins = settings.rowMargins
            numericValues = Dictionary(uniqueKeysWithValues: AppearanceCatalog.values.map { ($0.id, settings.value(of: $0)) })
        }

        func value(of item: AppearanceValue) -> Double {
            guard let value = numericValues[item.id] else {
                preconditionFailure("投稿の描画設定にない項目: \(item.id)")
            }
            return value
        }
    }
}
