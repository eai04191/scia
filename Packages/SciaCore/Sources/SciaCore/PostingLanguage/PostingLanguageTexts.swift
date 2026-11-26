import Foundation

/// 言語を選ぶシートと、投稿欄の言語のボタン。
public enum PostingLanguageTexts {
    public static let cancel = "キャンセル"
    public static let retry = "再試行"
    public static let searchPrompt = "言語の名前"
    public static let loadFailed = "言語のリストを読み込めませんでした"
    /// 言語を決めず、サーバーに任せるときの名前。
    public static let serverDecides = "サーバーに任せる"
}

/// 言語を選ぶシートで選ぶ対象。アカウントの既定を選ぶときは、題と、言語を決めない行の文言を変える。
public enum PostingLanguagePurpose: Sendable {
    /// 書いている投稿の言語。
    case post
    /// アカウントの既定の言語（docs/account-screen.mdの「投稿のデフォルト」）。
    case accountDefault

    /// シートの題。
    public var title: String {
        switch self {
        case .post: "投稿の言語"
        case .accountDefault: "言語"
        }
    }

    /// グループの見出し。
    public func sectionTitle(of kind: PostingLanguageSection.Kind) -> String {
        switch (kind, self) {
        case (.defaultLanguage, .post): "アカウントのデフォルト"
        case (.defaultLanguage, .accountDefault): "指定なし"
        case (.recent, .post): "最近選んだ言語"
        case (.recent, .accountDefault): "候補"
        case (.all, _): "すべての言語"
        }
    }

    /// 言語を決めない行の、名前の下に出す説明。
    public var serverDecidesNote: String {
        switch self {
        case .post: "デフォルトの言語が設定されていないため、サーバーが決めます"
        case .accountDefault: "言語を指定せず、投稿するときにサーバーが決めます"
        }
    }
}
