import SciaCore
import UIKit

/// 窓に開いたアカウントが使うプリセットの設定。セッションが窓に載せ、窓の中の部品が読む（docs/preset.md）。
/// 何段も親から作られる部品（投稿の本文の中のメディアのタイルなど）へ、引数で通さずに届けるため。
struct AppSettingsTrait: UITraitDefinition {
    struct Reference: Equatable, Sendable {
        let settings: AppSettings

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.settings === rhs.settings
        }
    }

    /// 窓に載せていないときは、アプリの設定を読む。
    static let defaultValue: Reference? = nil
}

extension UITraitCollection {
    @MainActor
    var appSettings: AppSettings {
        self[AppSettingsTrait.self]?.settings ?? AppDependencies.settings
    }
}

extension UIMutableTraits {
    var appSettings: AppSettings? {
        get { self[AppSettingsTrait.self]?.settings }
        set { self[AppSettingsTrait.self] = newValue.map(AppSettingsTrait.Reference.init) }
    }
}

/// 窓に設定を載せ、その設定のアクセントカラーとHDRの明るさを窓に当て続ける。
/// アカウントを切り替えたら、新しい設定に載せ替える。前の設定の見張りは、載せ替えた時点で止める。前の設定が変わったときに、前のアカウントの色で塗り直さないため。
/// 窓と違うプリセットを描く部品（プリセットを比較の見本など）では、その部品のビューに載せる。
@MainActor
final class WindowSettings {
    private weak var window: UIView?
    private let followsTint: Bool
    private var generation = 0

    /// - Parameter followsTint: アクセントカラーを窓のティントカラーにするか。ステータスバーの通知の窓は、ティントカラーを変えない。
    init(window: UIWindow, followsTint: Bool = true) {
        self.window = window
        self.followsTint = followsTint
    }

    init(view: UIView) {
        self.window = view
        self.followsTint = true
    }

    func use(_ settings: AppSettings) {
        window?.traitOverrides.appSettings = settings
        generation += 1
        follow(settings, generation: generation)
    }

    private func follow(_ settings: AppSettings, generation: Int) {
        guard let window, generation == self.generation else { return }
        withObservationTracking {
            if followsTint {
                window.tintColor = settings.accentColor.uiColor
            }
            window.traitOverrides.imageDynamicRange = UIImage.DynamicRange(settings.mediaDynamicRange)
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.follow(settings, generation: generation)
            }
        }
    }
}
