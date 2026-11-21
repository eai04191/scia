import Foundation

/// 入力欄の補完の候補のリスト。
public enum CompletionTexts {
    public static let listLabel = "補完の候補"
    public static let failed = "候補を読み込めませんでした"
    public static let loading = "候補を探しています"

    /// 読み込めなかった行の読み上げ。
    public static func failedAccessibilityLabel(message: String) -> String {
        "\(failed)。\(message)"
    }

    /// 手元から出した人の候補の、2段目の文。ハンドルに続けて、どこから出した人かを添える。
    /// ハンドルは長ければ切り、添えた理由は切らずに見せるため、ハンドルの範囲を添える。
    public static func localAccountSubtitle(acct: String, source: LocalMentionSource) -> PostTexts.EmphasizedText {
        let handle = "@\(acct)"
        let text = "\(handle)・\(source.title)"
        let start = text.range(of: handle)?.lowerBound ?? text.startIndex
        return PostTexts.EmphasizedText(text: text, emphasis: start..<text.index(start, offsetBy: handle.count))
    }

    /// ハッシュタグの候補の、最近の投稿の数。
    public static func recentUses(_ count: Int) -> String {
        "最近の投稿\(count.formatted())件"
    }

    /// ハッシュタグの候補の読み上げ。自分のタグなら、出した理由を続ける。
    public static func hashtagAccessibilityLabel(name: String, note: String? = nil) -> String {
        note.map { "ハッシュタグ \(name)、\($0)" } ?? "ハッシュタグ \(name)"
    }

    /// 絵文字の候補の読み上げ。カスタム絵文字は短縮名、Unicodeの絵文字は名前を渡す。
    public static func emojiAccessibilityLabel(name: String) -> String {
        "絵文字 \(name)"
    }
}

extension LocalMentionSource {
    /// 検索の結果より上に出る理由が分かるよう、候補に添える、どこから出した人か。
    public var title: String {
        switch self {
        case .reply: "返信先"
        case .recent: "前にメンションした人"
        }
    }
}

extension OwnHashtag.Source {
    /// 検索の結果より上に出る理由が分かるよう、候補に添える、自分のタグであること。
    public var title: String {
        switch self {
        case .featured(let count): "プロフィールのタグ・投稿\(count.formatted())件"
        case .recent: "最近使ったタグ"
        }
    }
}

extension CompletionKind {
    /// 一致する候補がないときに出す文言。
    public var emptyTitle: String {
        switch self {
        case .mention: "一致するアカウントがありません"
        case .hashtag: "一致するハッシュタグがありません"
        case .emoji: "一致する絵文字がありません"
        }
    }
}
