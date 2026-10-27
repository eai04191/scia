import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// 投稿の言語を選ぶシートの並びと、最近選んだ言語。
@Suite(.scratch)
@MainActor
struct PostingLanguageTests {
    private static let japanese = Locale(identifier: "ja_JP")
    private static let languages = [
        PostingLanguage(code: "en", name: "English"),
        PostingLanguage(code: "ja", name: "Japanese"),
        PostingLanguage(code: "fr", name: "French"),
        PostingLanguage(code: "zz", name: "Unknown Language"),
    ]

    private func sections(defaultCode: String? = "ja", recentCodes: [String] = [], languages: [PostingLanguage]? = languages, query: String = "") -> [PostingLanguageSection] {
        PostingLanguageSection.sections(defaultCode: defaultCode, recentCodes: recentCodes, languages: languages, query: query, locale: Self.japanese)
    }

    /// 既定の言語、最近選んだ言語、すべての言語の順に並べ、名前は端末の言語で書く。最近選んだ言語から既定の言語は除く。
    @Test func listsDefaultRecentAndAll() {
        let result = sections(recentCodes: ["fr", "ja"])

        #expect(result.map(\.kind) == [.defaultLanguage, .recent, .all])
        #expect(result[0].rows == [PostingLanguageRow(code: "ja", name: "日本語")])
        #expect(result[1].rows == [PostingLanguageRow(code: "fr", name: "フランス語")])
        #expect(Set(result[2].rows.map(\.code)) == ["en", "ja", "fr", "zz"])
    }

    /// 既定の言語がなければ、いちばん上をサーバーに任せる行にする。
    @Test func defaultRowLeavesLanguageToServerWithoutDefault() {
        #expect(sections(defaultCode: nil).first?.rows == [PostingLanguageRow(code: nil, name: "")])
    }

    /// 編集では、既定の言語がなくてもサーバーに任せる行を出さない。言語を送らなければ、サーバーは今の言語を残すため。
    @Test func editingDoesNotOfferServerDecision() {
        let result = PostingLanguageSection.sections(defaultCode: nil, offersServerDecision: false, recentCodes: [], languages: Self.languages, query: "", locale: Self.japanese)

        #expect(result.map(\.kind) == [.all])
    }

    /// 端末が名前を知らない言語は、サーバーの返す名前にし、知っている言語の後ろに並べる。
    @Test func unknownLanguageUsesServerNameAfterKnownOnes() {
        #expect(sections().last?.rows.last == PostingLanguageRow(code: "zz", name: "Unknown Language"))
    }

    /// 端末の言語の名前、サーバーの返す名前、コードのどれでも探せる。ひらがなとカタカナ、大文字と小文字は区別しない。サーバーに任せる行は探すと出さない。
    @Test(arguments: ["フランス", "ふらんす", "french", "FR"])
    func searchesByNameOrCode(query: String) {
        let result = sections(defaultCode: nil, query: query)

        #expect(result.map(\.kind) == [.all])
        #expect(result.first?.rows.map(\.code) == ["fr"])
    }

    /// 一覧を読んでいる間と読めなかったときも、既定と最近選んだ言語は選べ、すべての言語のまとまりは空のまま残して、状態を出す場所にする。
    @Test func keepsDefaultAndRecentWithoutLanguageList() {
        let result = sections(recentCodes: ["en"], languages: nil)

        #expect(result.map(\.kind) == [.defaultLanguage, .recent, .all])
        #expect(result[1].rows == [PostingLanguageRow(code: "en", name: "英語")])
        #expect(result[2].rows.isEmpty)
    }

    /// 選んだ言語は新しい順に5つまで覚え、同じ言語は先頭へ動かす。アカウントごとに分ける。
    @Test func recordsRecentLanguagesPerAccount() throws {
        let defaults = try #require(UserDefaults(suiteName: TestScratch.suiteName("PostingLanguageTests")))
        let recent = RecentPostingLanguages(defaults: defaults, account: "alice@example.social")

        for code in ["en", "fr", "de", "es", "it", "ko", "fr"] {
            recent.record(code)
        }

        #expect(recent.codes == ["fr", "ko", "it", "es", "de"])
        #expect(RecentPostingLanguages(defaults: defaults, account: "bob@example.social").codes.isEmpty)
    }
}
