import Observation
import UIKit

/// ホーム画面に出すアプリのアイコン。選んだものはシステムが覚えるため、AppSettingsには持たない。
enum AppIconChoice: CaseIterable {
    /// 青地に白（App/Resources/AppIcon.icon）。
    case standard
    /// 白地に青（App/Resources/AppIconLight.icon）。project.ymlの`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`に載せた名前と合わせる。
    case light

    /// `setAlternateIconName`に渡す名前。nilは主アイコン。
    var alternateIconName: String? {
        switch self {
        case .standard: nil
        case .light: "AppIconLight"
        }
    }

    var title: String {
        switch self {
        case .standard: "青地に白"
        case .light: "白地に青"
        }
    }

    /// 選ぶ行に出す絵。ビルドのたびにTools/render-app-icon-previews.shが.iconから描き出してアプリに入れる。
    var previewImage: UIImage? {
        UIImage(named: "\(alternateIconName ?? "AppIcon")Preview")
    }

}

/// いまのアプリのアイコン。設定を複数のウィンドウで開いていても、どれも同じ選択を表示するよう、シーンをまたいで1つを使う。
@MainActor
@Observable
final class AppIconSelection {
    private(set) var current: AppIconChoice

    init() {
        let name = UIApplication.shared.alternateIconName
        current = AppIconChoice.allCases.first { $0.alternateIconName == name } ?? .standard
    }

    /// 押した行にすぐチェックが移るよう、先に選択を変え、切り替えに失敗したら戻す。
    /// 切り替えの完了は、iOSが出す「アイコンを変更しました」を閉じるまで返ってこない。
    func select(_ choice: AppIconChoice) async throws {
        guard choice != current else { return }
        let previous = current
        current = choice
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
        } catch {
            current = previous
            throw error
        }
    }
}
