import SciaCore
import SwiftUI
import UIKit

/// 隔離した投稿について開発者に送る内容の画面。クラッシュと非公開の投稿を用意せずに、状態を並べる。送るボタンを押しても何も送らない。
enum CrashReportCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "カタログの読み込みの失敗" }
    }

    private static let environment = "Scia 1.0 (202611090500)、iPhone17,1、iOS 26.1"

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("誰でも読める投稿（URLだけ）", ["visibility": "public", "url": "https://stellaria.network/@alice/109000000000000000", "content": "<p>本文</p>"]),
            state("非公開の投稿（構造の要約）", [
                "visibility": "private",
                "url": "https://stellaria.network/@alice/109000000000000001",
                "content": "<p>これは非公開の投稿の本文です<br><br>abc 123 😀</p>",
                "spoiler_text": "注意書き",
                "emojis": [["shortcode": "blobcat"]],
                "media_attachments": [["type": "image", "description": "説明", "meta": ["original": ["width": 4000, "height": 300]]], ["type": "image", "meta": ["original": ["width": 1, "height": 1]]]],
                "poll": ["options": [Any]()],
                "quote": ["quoted_status": [String: Any]()],
            ]),
            CatalogState(title: "読み込み中") { host { try await Task.sleep(for: .seconds(3_600)); throw Failure() } },
            CatalogState(title: "読み込めなかった") { host { throw Failure() } },
        ]
    }

    @MainActor
    private static func state(_ title: String, _ status: [String: Any]) -> CatalogState {
        CatalogState(title: title) {
            host {
                try PostCrashReport(response: JSONSerialization.data(withJSONObject: status), environment: environment)
            }
        }
    }

    @MainActor
    private static func host(_ load: @escaping @MainActor () async throws -> PostCrashReport) -> UIView {
        let controller = PostCrashReportView.makeController(fallbackURL: URL(string: "https://stellaria.network/@alice/1"), load: load) { ErrorPresentation($0) } sendByMail: { _, _ in } sendByMastodon: { _, _ in }
        return CatalogControllerHost(controller, height: 640)
    }
}
