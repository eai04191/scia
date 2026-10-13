import Foundation
import SciaCore

/// シーンをまたいで共有する依存。
@MainActor
enum AppDependencies {
    /// Releaseビルドではパネルを出さないため、値を保存せず常に既定値を使う。
    static let tuning: TuningStore = {
        #if DEBUG
        TuningStore(defaults: .standard)
        #else
        TuningStore(defaults: nil)
        #endif
    }()
}
