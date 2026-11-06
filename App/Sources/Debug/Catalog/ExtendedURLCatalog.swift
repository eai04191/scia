#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// URLの後ろに続いた文字を知らせるシート。1つのURL、全体が収まる短いURL、長いURLと長い文、2つのURL、予約のときを並べる。押しても何も送らない。
enum ExtendedURLCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            state("1つのURL", [("https://example.com/news/2026/11/06/12345", "これいい記事")]),
            state("全体が収まる短いURL（カメラを動かさない）", [("https://ex.jp/a", "読んだ")]),
            state("長いURLと長い文（端をフェードで消す）", [(
                "https://example.com/articles/2026/11/06/very-long-slug-that-keeps-going-and-going-forever?utm_source=share",
                "これは本当に長い感想で、どこまでも続いていく文章です"
            )]),
            state("2つのURL", [("https://a.example/news/1", "これ"), ("https://b.example/blog/2", "あれも")]),
            state("予約", [("https://example.com/news/2026/11/06/12345", "これいい記事")], scheduling: true),
        ]
    }

    @MainActor
    private static func state(_ title: String, _ pairs: [(url: String, continuation: String)], scheduling: Bool = false) -> CatalogState {
        CatalogState(title: title) {
            var offset = 0
            let found = pairs.map { pair in
                defer { offset += pair.url.utf16.count + pair.continuation.utf16.count + 1 }
                return ExtendedURL(insertedURL: pair.url, continuation: pair.continuation, offset: offset + pair.url.utf16.count)
            }
            guard let prompt = ExtendedURLPrompt(found, scheduling: scheduling) else { return UIView() }
            let view = ExtendedURLView(prompt: prompt, timing: ExtendedURLTiming(tuning: AppDependencies.tuning), choose: { _ in })
            return CatalogControllerHost(UIHostingController(rootView: view), height: pairs.count > 1 ? 400 : 320)
        }
    }
}
#endif
