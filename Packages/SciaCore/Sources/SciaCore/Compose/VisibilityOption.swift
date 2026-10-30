/// 公開範囲の選択肢の見た目。
public struct VisibilityOption: Sendable {
    public let visibility: Status.Visibility
    public let title: String
    public let symbolName: String

    public init(_ visibility: Status.Visibility) {
        self.visibility = visibility
        (title, symbolName) = switch visibility {
        case .public: ("公開", "globe")
        case .unlisted: ("ひかえめな公開", "moon")
        case .private: ("フォロワーのみ", "lock")
        case .direct: ("メンションした相手のみ", "at")
        case .other(let rawValue): (rawValue, "questionmark.circle")
        }
    }

    public static let choices: [VisibilityOption] = [.public, .unlisted, .private, .direct].map(VisibilityOption.init)
}
