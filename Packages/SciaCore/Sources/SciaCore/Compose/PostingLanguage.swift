public import Foundation
public import Observation

/// 投稿に付けられる言語。サーバーが受け付ける言語の一覧（`GET /api/v1/instance/languages`）の1件。決まりはdocs/compose.mdの「投稿の言語」にある。
public struct PostingLanguage: Decodable, Hashable, Sendable, Identifiable {
    /// ISO 639-1か639-3のコード。地域を付けたもの（`zh-TW`など）もある。
    public let code: String
    /// サーバーが返す英語の名前。
    public let name: String

    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// `locale`の言語で書いた名前。端末が知らない言語なら、サーバーの返す名前にする。
    public func localizedName(in locale: Locale) -> String {
        Self.localizedName(of: code, in: locale) ?? name
    }

    /// `code`の言語の、`locale`の言語で書いた名前。端末が知らない言語ならnil。
    public static func localizedName(of code: String, in locale: Locale) -> String? {
        locale.localizedString(forIdentifier: code)
    }

    /// 既定と違う言語を選んでいる間に見せるコード。大文字にする。
    public static func badgeText(of code: String) -> String {
        code.uppercased()
    }
}

/// 言語を選ぶシートの1行。
public struct PostingLanguageRow: Hashable, Sendable, Identifiable {
    /// 送る言語。nilなら言語を送らず、サーバーに任せる。
    public let code: String?
    /// 端末の言語で書いた名前。サーバーに任せる行では空。
    public let name: String

    public var id: String { code ?? "" }

    public init(code: String?, name: String) {
        self.code = code
        self.name = name
    }
}

/// 言語を選ぶシートのまとまり。
public struct PostingLanguageSection: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// アカウントの既定の言語。既定がなければ、サーバーに任せる行。
        case defaultLanguage
        /// 最近選んだ言語。既定の言語は除く。
        case recent
        /// サーバーが受け付けるすべての言語。
        case all
    }

    public let kind: Kind
    public let rows: [PostingLanguageRow]

    public init(kind: Kind, rows: [PostingLanguageRow]) {
        self.kind = kind
        self.rows = rows
    }

    /// 並べるまとまり。空のまとまりは除く。
    /// - Parameters:
    ///   - defaultCode: アカウントの既定の言語。なければnil。
    ///   - offersServerDecision: 既定の言語がないときに、サーバーに任せる行を出す。編集では出さない（言語を送らなければ、サーバーは今の言語を残すため）。
    ///   - recentCodes: 最近選んだ言語。新しい順。
    ///   - languages: サーバーが受け付ける言語。読んでいる間と読めなかったときはnilで、すべての言語のまとまりを出さない。
    ///   - query: 名前で探す語。空なら絞らない。端末の言語の名前、サーバーの返す名前、コードのどれかに含まれる行だけを残す。ひらがなとカタカナ、全角と半角、大文字と小文字は区別しない。
    public static func sections(defaultCode: String?, offersServerDecision: Bool = true, recentCodes: [String], languages: [PostingLanguage]?, query: String, locale: Locale) -> [PostingLanguageSection] {
        let serverNames = Dictionary((languages ?? []).map { ($0.code, $0.name) }, uniquingKeysWith: { first, _ in first })
        func row(_ code: String) -> PostingLanguageRow {
            PostingLanguageRow(code: code, name: PostingLanguage.localizedName(of: code, in: locale) ?? serverNames[code] ?? code)
        }
        // ひらがなで打っても、カタカナの名前（「フランス語」）に一致させる。
        func folded(_ text: String) -> String {
            text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text
        }
        let query = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        func matches(_ row: PostingLanguageRow) -> Bool {
            guard !query.isEmpty else { return true }
            guard let code = row.code else { return false }
            let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
            return [row.name, serverNames[code] ?? "", code].contains { folded($0).range(of: query, options: options) != nil }
        }
        let defaultRows = defaultCode.map { [row($0)] } ?? (offersServerDecision ? [PostingLanguageRow(code: nil, name: "")] : [])
        var seen: Set<String> = defaultCode.map { [$0] } ?? []
        let recent = recentCodes.filter { seen.insert($0).inserted }.map(row)
        // 端末が名前を知っている言語を、名前の順で先に並べる。知らない言語はサーバーの英語の名前になり、混ぜるとラテン文字の名前が先に来て、よく使う言語が下に押し出されるため。
        let all = (languages ?? [])
            .map { (isLocalized: PostingLanguage.localizedName(of: $0.code, in: locale) != nil, row: PostingLanguageRow(code: $0.code, name: $0.localizedName(in: locale))) }
            .sorted { lhs, rhs in
                lhs.isLocalized != rhs.isLocalized ? lhs.isLocalized : lhs.row.name.localizedStandardCompare(rhs.row.name) == .orderedAscending
            }
            .map(\.row)
        return [
            PostingLanguageSection(kind: .defaultLanguage, rows: defaultRows.filter(matches)),
            PostingLanguageSection(kind: .recent, rows: recent.filter(matches)),
            PostingLanguageSection(kind: .all, rows: all.filter(matches)),
        ].filter { !$0.rows.isEmpty || ($0.kind == .all && languages == nil) }
    }
}

/// 言語を選ぶシートで選んだ言語を、ログインしているアカウントごとに新しい順で覚える。
/// `RecentMentions`と同じく、複数のウィンドウで開いても上書きし合わないよう、手元に持たずに毎回UserDefaultsを読み書きする。
@MainActor
public final class RecentPostingLanguages {
    private let defaults: UserDefaults
    private let key: String
    /// 覚えておく数。
    public static let capacity = 5

    /// - Parameter account: ログインしているアカウントのハンドル（`Credential.handle`）。
    public init(defaults: UserDefaults, account: String) {
        self.defaults = defaults
        key = AccountScopedDefaults.key("recentPostingLanguages", account: account)
    }

    /// 新しい順のコード。
    public var codes: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func record(_ code: String) {
        var codes = codes
        codes.removeAll { $0 == code }
        codes.insert(code, at: 0)
        defaults.set(Array(codes.prefix(Self.capacity)), forKey: key)
    }
}

/// 言語を選ぶシートの状態。決まりはdocs/compose.mdの「投稿の言語」にある。
@MainActor
@Observable
public final class PostingLanguagePicker {
    /// サーバーが受け付ける言語の読み込み。
    public enum Languages {
        case loading
        case loaded([PostingLanguage])
        case failed(any Error)
    }

    /// アカウントの既定の言語。なければnil。
    public let defaultCode: String?
    /// 今選んでいる言語。サーバーに任せていればnil。
    public let selectedCode: String?
    /// 最近選んだ言語。新しい順。開いた時点で決め、開いている間に選んでも変えない。
    public let recentCodes: [String]
    /// 既定の言語がないときに、サーバーに任せる行を出す。
    public let offersServerDecision: Bool
    /// 名前で探す語。
    public var query = ""
    public private(set) var languages: Languages = .loading

    private let load: @Sendable () async throws -> [PostingLanguage]

    public init(defaultCode: String?, selectedCode: String?, recentCodes: [String], offersServerDecision: Bool = true, load: @escaping @Sendable () async throws -> [PostingLanguage]) {
        self.defaultCode = defaultCode
        self.selectedCode = selectedCode
        self.recentCodes = recentCodes
        self.offersServerDecision = offersServerDecision
        self.load = load
    }

    /// サーバーが受け付ける言語を読む。読み直すときも、読み込み中に戻してから読む。
    public func loadLanguages() async {
        languages = .loading
        do {
            languages = .loaded(try await load())
        } catch {
            languages = .failed(error)
        }
    }

    /// 並べるまとまり。
    public func sections(locale: Locale) -> [PostingLanguageSection] {
        let loaded: [PostingLanguage]? = if case .loaded(let languages) = languages { languages } else { nil }
        return PostingLanguageSection.sections(defaultCode: defaultCode, offersServerDecision: offersServerDecision, recentCodes: recentCodes, languages: loaded, query: query, locale: locale)
    }
}
