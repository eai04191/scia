import Foundation
@testable import SciaCore
import Testing

struct PostCrashReportTests {
    private let environment = "Scia 1.0 (1)、iPhone17,1、iOS 26.1"

    private func report(_ fields: [String: Any]) throws -> PostCrashReport {
        var status: [String: Any] = ["id": "109", "content": "", "visibility": "private", "url": "https://example.com/@secret/109"]
        status.merge(fields) { _, new in new }
        return try PostCrashReport(response: JSONSerialization.data(withJSONObject: status), environment: environment)
    }

    private func decodedMasked(_ fields: [String: Any]) throws -> Status {
        let masked = try #require(try report(fields).maskedJSON)
        return try MastodonDecoder.make().decode(Status.self, from: Data(masked.utf8))
    }

    @Test(arguments: ["public", "unlisted"])
    func 誰でも読める投稿はURLと環境だけを送る(visibility: String) throws {
        let report = try report(["visibility": visibility, "content": "<p>本文</p>"])
        #expect(report.text == "https://example.com/@secret/109\n\n\(environment)")
        #expect(report.maskedJSON == nil)
    }

    @Test(arguments: ["private", "direct", "limited"])
    func 誰でも読めるとは言えない投稿はURLを送らず要約にする(visibility: String) throws {
        let report = try report(["visibility": visibility])
        #expect(!report.text.contains("example.com"))
        #expect(report.text.hasPrefix("本文は含まれていません。\n\n"))
        #expect(report.text.hasSuffix(environment))
    }

    @Test func ブーストは元の投稿で判断する() throws {
        let report = try report(["visibility": "public", "reblog": ["visibility": "private", "url": "https://example.com/@secret/1", "content": "<p>x</p>"]])
        #expect(report.text.hasPrefix("本文は含まれていません。"))
    }

    @Test func 要約は構造を人が読める形で並べる() throws {
        let text = try report([
            "content": "<p>あ亜a1😀&amp;<br><br /></p><p>x</p>",
            "spoiler_text": "注意",
            "emojis": [["shortcode": "secret"]],
            "media_attachments": [
                ["type": "image", "description": "説明", "meta": ["original": ["width": 4000, "height": 300]]],
                ["type": "video"],
            ],
            "poll": ["options": [Any]()],
            "quote": ["quoted_status": ["quote": ["quoted_status": [String: Any]()]]],
            "card": ["title": "t"],
        ]).text
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            "本文は含まれていません。",
            "",
            "本文: 7文字、改行2回（連続は最大2回）",
            "文字の種類: かな、漢字、英数字、絵文字1個、カスタム絵文字1個、制御文字なし",
            "結合文字の連続: 最大0文字",
            "HTML: 段落2個、改行2個",
            "注意書き: あり（2文字）",
            "添付: 画像1枚（4000×300）、動画1枚（大きさ不明）、代替テキストあり1個",
            "投票: 選択肢0個",
            "引用: 2段",
            "リンクカード: あり",
            environment,
        ])
    }

    @Test func 要約にも置き換えたJSONにも本文と個人の情報が入らない() throws {
        let fields: [String: Any] = [
            "content": "<p class=\"secret-class\">ひみつSecretWord 123 <a href=\"https://secret.example/\">リンク</a></p>",
            "spoiler_text": "ちゅういSecret",
            "account": ["id": "999", "username": "alice", "acct": "alice@secret.example", "display_name": "アリス", "note": "<p>自己紹介</p>", "avatar": "https://secret.example/a.png"],
            "mentions": [["acct": "bob@secret.example"]],
            "tags": [["name": "secrettag"]],
            "emojis": [["shortcode": "secretemoji", "url": "https://secret.example/e.png"]],
            "media_attachments": [["id": "777", "type": "image", "url": "https://secret.example/m.png", "description": "ひみつの説明", "blurhash": "SECRETHASH", "meta": ["original": ["width": 10, "height": 20, "secret": "x"]]]],
            "poll": ["id": "888", "options": [["title": "ひみつの選択肢"]]],
            "card": ["url": "https://secret.example/", "title": "ひみつのカード", "image": "https://secret.example/c.png", "provider_name": "SecretProvider"],
            "server_extension_field": "SecretExtension",
            "application": ["name": "SecretApp"],
        ]
        let report = try report(fields)
        let combined = report.text + (report.maskedJSON ?? "")
        for secret in ["ひみつ", "Secret", "secret", "alice", "bob", "アリス", "999", "777", "888", "109", "ちゅうい"] {
            #expect(!combined.contains(secret), "\(secret)")
        }
    }

    @Test func 置き換えは長さと崩れやすい文字を保つ() {
        #expect(PostMasking.text("あア亜Aa1 。😀\u{200D}\u{0301}\u{202E}") == "ああ亜Aa0 。😀\u{200D}\u{0301}\u{202E}")
        #expect(PostMasking.text("مرحبا").unicodeScalars.count == 5)
        #expect(PostMasking.text("שלום") == "אאאא")
        #expect(PostMasking.text("０９०Ⅷ①") == "00000")
    }

    @Test func 置き換えたJSONはタグの構造を保つ() {
        #expect(PostMasking.html("<p>a<br/>b &lt; <a href=\"https://s/\" class=\"c\">x</a></p>") == "<p>a<br />a &amp; <a href=\"https://example.invalid/\">a</a></p>")
    }

    @Test func 知らないタグの名前と種類は出さない() throws {
        let report = try report([
            "content": "<alice123>本文</alice123><p>x</p>",
            "media_attachments": [["type": "alice-type"]],
            "card": ["type": "alice-card"],
        ])
        #expect(!(report.text + (report.maskedJSON ?? "")).contains("alice"))
        #expect(report.text.contains("HTML: 段落1個、そのほか1個"))
    }

    @Test func 閉じていない山かっこは文字として扱う() {
        #expect(PostHTML.tokens("a<b") == [.text("a<b")])
        #expect(PostHTML.tokens("1<2>3") == [.text("1<"), .text("2>3")])
    }

    @Test func 置き換えたJSONはタイムラインに流せる() throws {
        let status = try decodedMasked([
            "content": "<p>本文</p>",
            "account": ["display_name": "名前"],
            "media_attachments": [["type": "image", "meta": ["original": ["width": 10, "height": 20]]]],
            "poll": ["options": [["title": "選択肢", "votes_count": 1]]],
            "card": ["title": "カード", "image": "https://x/"],
            "quote": ["quoted_status": ["content": "<p>引用</p>", "account": [String: Any]()]],
        ])
        #expect(status.content == "<p>亜亜</p>")
        #expect(status.mediaAttachments.count == 1)
        #expect(status.poll?.options.count == 1)
        #expect(status.card != nil)
        #expect(status.quote?.quotedStatus?.content == "<p>亜亜</p>")
    }

    @Test func JSONでない応答は失敗にする() {
        #expect(throws: PostCrashReport.Failure.unreadableResponse) {
            try PostCrashReport(response: Data("<html>".utf8), environment: "")
        }
    }
}
