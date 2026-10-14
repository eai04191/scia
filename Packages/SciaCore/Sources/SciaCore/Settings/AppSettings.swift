public import Foundation
public import Observation

/// 使う人が設定画面で選ぶ値。変更はObservationで購読できる。
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// モバイル通信とインターネット共有でも、一覧のサムネイルに元の画像を読む。
    /// オフなら、サーバーが縮めたプレビュー画像を読む。
    public var usesOriginalThumbnailsOnExpensiveNetwork: Bool {
        didSet { defaults.set(usesOriginalThumbnailsOnExpensiveNetwork, forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) }
    }

    /// 「undefined」や「Screenshot」のような、説明にならない代替テキストを付いていないものとして扱う。
    public var ignoresUselessAltText: Bool {
        didSet { defaults.set(ignoresUselessAltText, forKey: Keys.ignoresUselessAltText) }
    }

    /// 投稿の名前の行に、表示名とacctをどう並べるか。
    public var statusNameStyle: StatusNameStyle {
        didSet { defaults.set(statusNameStyle.rawValue, forKey: Keys.statusNameStyle) }
    }

    public var statusTimeStyle: StatusTimeStyle {
        didSet { defaults.set(statusTimeStyle.rawValue, forKey: Keys.statusTimeStyle) }
    }

    public var avatarShape: AvatarShape {
        didSet { defaults.set(avatarShape.rawValue, forKey: Keys.avatarShape) }
    }

    /// 一覧で、GIFなどのアニメーションするアイコンを動かす。オフなら最初のコマで止めた版を読む。
    public var animatesAvatars: Bool {
        didSet { defaults.set(animatesAvatars, forKey: Keys.animatesAvatars) }
    }

    private enum Keys {
        static let usesOriginalThumbnailsOnExpensiveNetwork = "settings.usesOriginalThumbnailsOnExpensiveNetwork"
        static let ignoresUselessAltText = "settings.ignoresUselessAltText"
        static let statusNameStyle = "settings.statusNameStyle"
        static let statusTimeStyle = "settings.statusTimeStyle"
        static let avatarShape = "settings.avatarShape"
        static let animatesAvatars = "settings.animatesAvatars"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        usesOriginalThumbnailsOnExpensiveNetwork = defaults.object(forKey: Keys.usesOriginalThumbnailsOnExpensiveNetwork) as? Bool ?? true
        ignoresUselessAltText = defaults.object(forKey: Keys.ignoresUselessAltText) as? Bool ?? true
        statusNameStyle = defaults.string(forKey: Keys.statusNameStyle).flatMap(StatusNameStyle.init(rawValue:)) ?? .nameAndAcct
        statusTimeStyle = defaults.string(forKey: Keys.statusTimeStyle).flatMap(StatusTimeStyle.init(rawValue:)) ?? .relative
        avatarShape = defaults.string(forKey: Keys.avatarShape).flatMap(AvatarShape.init(rawValue:)) ?? .roundedSquare
        animatesAvatars = defaults.object(forKey: Keys.animatesAvatars) as? Bool ?? false
    }
}
