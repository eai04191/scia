public import Foundation

/// カスタム絵文字ごとに選ぶ描き方（docs/animated-custom-emoji.mdの「絵文字ごとの描き方」）。
public enum CustomEmojiDisplay: String, CaseIterable, Codable, Sendable {
    /// 既定。ほかの絵文字と同じく描き、設定に従って動かす。
    case plays
    /// 半分の速さで動かす。
    case playsSlowly
    /// 動かさず、動かない版で描く。
    case still
    /// 画像を描かず、`:shortcode:`の文字を出す。
    case shortcode
    /// 何も出さない。
    case hidden

    public var title: String {
        switch self {
        case .plays: "表示する"
        case .playsSlowly: "遅く再生"
        case .still: "アニメーションしない"
        case .shortcode: "ショートコードで表示"
        case .hidden: "表示しない"
        }
    }

    /// コマを送る速さの、元の速さに対する割合。画像を描かないか、動かさないならnil。
    public var playbackRate: Double? {
        switch self {
        case .plays: 1
        case .playsSlowly: 0.5
        case .still, .shortcode, .hidden: nil
        }
    }

    /// 動きだけを変える選択肢か。動かない絵文字では、選んでも見た目が変わらない。
    public var changesOnlyMotion: Bool {
        switch self {
        case .playsSlowly, .still: true
        case .plays, .shortcode, .hidden: false
        }
    }

    /// 選べる描き方。動かないと分かった絵文字では、動きだけを変える選択肢を出さない。ただし、選んである描き方は残す。
    public static func choices(isKnownStill: Bool, current: CustomEmojiDisplay) -> [CustomEmojiDisplay] {
        allCases.filter { !isKnownStill || !$0.changesOnlyMotion || $0 == current }
    }

    /// 画像を描くか。
    public var drawsImage: Bool {
        switch self {
        case .plays, .playsSlowly, .still: true
        case .shortcode, .hidden: false
        }
    }
}

/// 同じカスタム絵文字を見分けるもの。ショートコードと、絵文字を持つサーバー。
/// 画像のURLは、ほかのサーバーの絵文字ではログインしているサーバーが持つコピーのURLになり、アカウントによって変わるため使わない。
public struct CustomEmojiID: Hashable, Codable, Sendable {
    public let shortcode: String
    /// サーバーの名前。大文字と小文字を区別しないため、小文字にして持つ。
    public let domain: String

    public init(shortcode: String, domain: String) {
        self.shortcode = shortcode
        self.domain = domain.lowercased()
    }
}

extension CustomEmoji {
    /// - Parameter localServer: ログインしているサーバーの名前。`domain`がない絵文字のサーバーにする。
    public func id(localServer: String) -> CustomEmojiID {
        CustomEmojiID(shortcode: shortcode, domain: domain ?? localServer)
    }
}

/// 既定から描き方を変えた絵文字。
public struct CustomEmojiDisplayRule: Codable, Hashable, Sendable, Identifiable {
    public let id: CustomEmojiID
    public var display: CustomEmojiDisplay
    /// 設定の一覧に出す画像。描き方を変えたときに見ていた絵文字の画像。
    public var url: URL
    public var staticUrl: URL

    public init(id: CustomEmojiID, display: CustomEmojiDisplay, url: URL, staticUrl: URL) {
        self.id = id
        self.display = display
        self.url = url
        self.staticUrl = staticUrl
    }

    /// 一覧に出す絵文字。
    public var emoji: CustomEmoji {
        CustomEmoji(shortcode: id.shortcode, url: url, staticUrl: staticUrl, domain: id.domain)
    }
}

/// 文字を描くときに引く、絵文字ごとの描き方。
public struct CustomEmojiDisplays: Equatable, Sendable {
    private let displays: [CustomEmojiID: CustomEmojiDisplay]
    /// `domain`がない絵文字を持つサーバー。分からなければ、そうした絵文字はすべて既定で描く。
    private let localServer: String?

    public init(rules: [CustomEmojiDisplayRule], localServer: String?) {
        displays = Dictionary(rules.map { ($0.id, $0.display) }, uniquingKeysWith: { _, last in last })
        self.localServer = localServer
    }

    /// どの絵文字も既定で描く。
    public static let none = CustomEmojiDisplays(rules: [], localServer: nil)

    public func display(of emoji: CustomEmoji) -> CustomEmojiDisplay {
        display(shortcode: emoji.shortcode, domain: emoji.domain)
    }

    /// 画像のURLのないリアクションのように、絵文字の形になっていないものも、ショートコードとサーバーで引く。
    /// - Parameter domain: 絵文字を持つサーバー。nilならログインしているサーバー。
    public func display(shortcode: String, domain: String?) -> CustomEmojiDisplay {
        guard !displays.isEmpty, let domain = domain ?? localServer else { return .plays }
        return displays[CustomEmojiID(shortcode: shortcode, domain: domain)] ?? .plays
    }
}
