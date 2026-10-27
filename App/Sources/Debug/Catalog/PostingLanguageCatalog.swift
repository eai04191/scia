#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// 投稿の言語を選ぶシート。サーバーに問い合わせずに、言語の一覧の読み込み中と失敗、既定の言語がないとき、最近選んだ言語があるときを並べる。選んでも何も変えない。
enum PostingLanguageCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "サーバーに接続できませんでした。" }
    }

    private static let languages = [
        PostingLanguage(code: "ja", name: "Japanese"),
        PostingLanguage(code: "en", name: "English"),
        PostingLanguage(code: "fr", name: "French"),
        PostingLanguage(code: "zh-TW", name: "Chinese (Taiwan)"),
        PostingLanguage(code: "zba", name: "Balaibalan"),
    ]

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("言語の一覧を読み込み中", load: { try await Task.sleep(for: .seconds(3_600)); return [] }),
            state("言語の一覧を読めなかった", load: { throw Failure() }),
            state("既定と違う言語を選んでいる（最近選んだ言語あり）", selectedCode: "fr", recentCodes: ["fr", "zh-TW"]),
            state("既定の言語がない（サーバーに任せている）", defaultCode: nil, selectedCode: nil),
        ]
    }

    @MainActor
    private static func state(
        _ title: String,
        defaultCode: String? = "ja",
        selectedCode: String? = "ja",
        recentCodes: [String] = [],
        load: @escaping @Sendable () async throws -> [PostingLanguage] = { PostingLanguageCatalog.languages }
    ) -> CatalogState {
        CatalogState(title: title) {
            let picker = PostingLanguagePicker(defaultCode: defaultCode, selectedCode: selectedCode, recentCodes: recentCodes, load: load)
            let controller = UIHostingController(rootView: PostingLanguageView(picker: picker, onSelect: { _ in }, close: {}))
            return CatalogControllerHost(controller, height: 560)
        }
    }
}
#endif
