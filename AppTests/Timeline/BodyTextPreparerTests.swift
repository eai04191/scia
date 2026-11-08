import Foundation
import SciaCore
import SciaTesting
import Testing
import TextKit2Label
import UIKit
@testable import Scia

/// タイムラインの投稿の本文を、メインスレッドの外で先に作って並べておく部品。
@Suite(.scratch)
@MainActor
struct BodyTextPreparerTests {
    private let width: CGFloat = 300
    private let emoji = CustomEmoji(shortcode: "blob", url: URL(string: "https://example.com/blob.gif")!, staticUrl: URL(string: "https://example.com/blob.png")!)

    private func builder(emojiImages: EmojiImageStore<UIImage> = .offline, preparer: BodyTextPreparer? = nil) -> PostContentBuilder {
        PostContentBuilder(tuning: AppDependencies.tuning, settings: AppDependencies.settings, emojiImages: emojiImages, mediaImages: .offline, avatarImages: .offline, preparedBodies: preparer)
    }

    private func status(_ content: String, emojis: [CustomEmoji] = [], language: String = "ja") -> Status {
        Status(
            id: "1",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil),
            content: content,
            spoilerText: "",
            language: language,
            url: nil,
            emojis: emojis
        )
    }

    private var longContent: String {
        (1...6).map { _ in "<p>\(String(repeating: "長い本文の段落です。禁則処理「かぎかっこ」も入れます。English words too. ", count: 4))</p>" }.joined()
    }

    private func label() -> LinkLabel {
        let label = LinkLabel()
        label.numberOfLines = 0
        label.drawsWithTextKit = true
        label.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        return label
    }

    private func geometry(of label: EmojiLabel) -> BodyTextPreparer.Geometry {
        BodyTextPreparer.Geometry(style: label.textKitStyle, width: width)
    }

    /// 先に作るのを頼んで、作り終えるまで待つ。作っている間にカスタム絵文字の画像の状態が変われば、タイムラインと同じく頼み直す。
    private func prepare(_ status: Status, builder: PostContentBuilder, preparer: BodyTextPreparer, geometry: BodyTextPreparer.Geometry?, translation: RichText? = nil) async throws -> BodyTextPreparer.Prepared {
        try await waitUntil {
            preparer.prepare([status], renderer: builder.postBodyRenderer(of:translation:), geometry: geometry, truncation: { _ in nil }, translation: { _ in translation }, guessesLinkCardDirections: false)
            return preparer.prepared(for: status, translation: translation, renderer: builder.postBodyRenderer(of: status, translation: translation)) != nil
        }
        return try #require(preparer.prepared(for: status, translation: translation, renderer: builder.postBodyRenderer(of: status, translation: translation)))
    }

    /// メインスレッドの外で作った本文は、行を組み立てるときにメインスレッドで作る本文と、文字も属性も同じになる。
    @Test func preparedTextMatchesMainThread() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status(longContent + "<p>絵文字 :blob: と 😀 と <a href=\"https://example.com\">リンク</a></p>", emojis: [emoji])
        let prepared = try await prepare(status, builder: builder, preparer: preparer, geometry: geometry(of: label()))
        let onMain = builder.body(of: status, base: .cell(), enlargesEmojiOnly: true)

        #expect(EmojiLabel.hasSameContent(prepared.text, onMain))
    }

    /// 行を組み立てると、作っておいた本文と並びを使う。ラベルは並べ直さずに、作っておいた並びで描き、メインスレッドで並べたときと同じ大きさになる。
    @Test func configurationUsesPreparedLayout() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status(longContent)
        let prepared = try await prepare(status, builder: builder, preparer: preparer, geometry: geometry(of: label()))
        let configuration = builder.configuration(for: status, base: .cell())
        #expect(configuration.body === prepared.text)
        let layout = try #require(configuration.preparedBodyLayout)

        let usingPrepared = label()
        usingPrepared.attributedText = configuration.body
        usingPrepared.usePreparedLayout(layout)
        let onMain = label()
        onMain.attributedText = builder.body(of: status, base: .cell(), enlargesEmojiOnly: true)

        let fitting = CGSize(width: width, height: .greatestFiniteMagnitude)
        #expect(usingPrepared.sizeThatFits(fitting) == onMain.sizeThatFits(fitting))
        #expect(usingPrepared.textKitBaselines(width: width) == onMain.textKitBaselines(width: width))
        let drawn = usingPrepared.textLayout(of: try #require(usingPrepared.attributedText))
        #expect(drawn.layoutManager === layout.entry(width: width, maximumLines: 0)?.layout.layoutManager)
    }

    /// ラベルの値が並べたときと違えば、作っておいた並びを使わずに並べ直す。
    @Test func labelWithDifferentStyleIgnoresPreparedLayout() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status(longContent)
        let prepared = try await prepare(status, builder: builder, preparer: preparer, geometry: geometry(of: label()))
        let other = label()
        other.lineBreakMode = .byCharWrapping
        other.attributedText = prepared.text
        other.usePreparedLayout(prepared.layout)

        #expect(other.preparedLayoutWidth == nil)
    }

    /// 本文のカスタム絵文字の画像の状態が、作ったときから変われば、作っておいた本文を使わず、頼み直すと作り直す。
    /// 読み込み中の絵文字は場所を空けて描き、読めなかった絵文字は文字で描くため。
    @Test func emojiStateChangeInvalidatesPreparedText() async throws {
        let preparer = BodyTextPreparer()
        let gate = Gate()
        let store = EmojiImageStore<UIImage> { _ in
            try await gate.wait()
            throw URLError(.notConnectedToInternet)
        }
        let builder = builder(emojiImages: store, preparer: preparer)
        let status = status("<p>絵文字 :blob:</p>", emojis: [emoji])
        let loading = try await prepare(status, builder: builder, preparer: preparer, geometry: nil)

        gate.open()
        try await waitUntil { store.hasFailed(emoji.staticUrl) }

        #expect(preparer.prepared(for: status, translation: nil, renderer: builder.postBodyRenderer(of: status)) == nil)
        let failed = try await prepare(status, builder: builder, preparer: preparer, geometry: nil)
        #expect(!loading.text.string.contains(":blob:"))
        #expect(failed.text.string.contains(":blob:"))
    }

    /// 訳文で頼んだ本文は訳文で作り、原文で描くときには使わない。
    @Test func preparesTranslatedBody() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status("<p>Hello</p>", emojis: [])
        let translation = RichText(blocks: [RichText.Block(inlines: [.text("こんにちは", [])])])

        let prepared = try await prepare(status, builder: builder, preparer: preparer, geometry: nil, translation: translation)

        #expect(prepared.text.string == "こんにちは")
        #expect(preparer.prepared(for: status, translation: nil, renderer: builder.postBodyRenderer(of: status)) == nil)
    }

    /// 訳文は翻訳先の言語の字形で描き、原文は投稿の言語の字形で描く。先に作るときも同じ字形にする。
    @Test func translatedBodyUsesGlyphsOfTargetLanguage() async throws {
        let settings = AppSettings(defaults: TestScratch.defaults("BodyTextPreparerTests.glyphs"))
        settings.autoTranslationTarget = "ja"
        let preparer = BodyTextPreparer()
        let builder = PostContentBuilder(tuning: AppDependencies.tuning, settings: settings, emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, preparedBodies: preparer)
        let chinese = status("<p>你好</p>", language: "zh")
        let translation = RichText(blocks: [RichText.Block(inlines: [.text("直す", [])])])
        func language(_ text: NSAttributedString) -> String? {
            text.attribute(.languageIdentifier, at: 0, effectiveRange: nil) as? String
        }

        #expect(language(builder.configuration(for: chinese, base: .cell()).body) == "zh-Hans")
        #expect(language(builder.configuration(for: chinese, translation: translation, base: .cell()).body) == "ja")
        let prepared = try await prepare(chinese, builder: builder, preparer: preparer, geometry: nil, translation: translation)
        #expect(language(prepared.text) == "ja")
    }

    /// 本文の描き方（文字の大きさや行間など）が作ったときから変われば、作っておいた本文を使わない。
    @Test func styleChangeInvalidatesPreparedText() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status(longContent)
        _ = try await prepare(status, builder: builder, preparer: preparer, geometry: nil)
        var renderer = builder.postBodyRenderer(of: status)
        renderer.lineSpacing += 1

        #expect(preparer.prepared(for: status, translation: nil, renderer: renderer) == nil)
    }

    /// 投稿が編集されて本文が変われば、作っておいた本文を使わない。
    @Test func editedContentInvalidatesPreparedText() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        _ = try await prepare(status(longContent), builder: builder, preparer: preparer, geometry: nil)
        let edited = status("<p>編集した本文</p>")

        #expect(preparer.prepared(for: edited, translation: nil, renderer: builder.postBodyRenderer(of: edited)) == nil)
    }

    /// リンクカードの文字の書く方向も、メインスレッドの外で判定しておく。
    @Test func guessesLinkCardDirectionsAhead() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let title = "مرحبا بكم في موقعنا \(unique(in: "٠١٢٣٤٥٦٧٨٩ابتثجح"))"
        let description = "ようこそ、私たちのサイトへ \(unique(in: "あいうえおかきくけこさしすせそた"))"
        let status = Status(
            id: "1",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil),
            content: "<p>本文</p>",
            spoilerText: "",
            url: nil,
            card: PreviewCard(url: URL(string: "https://example.com/page")!, title: title, description: description, type: .link, providerName: "")
        )
        preparer.prepare([status], renderer: builder.postBodyRenderer(of:translation:), geometry: nil, truncation: { _ in nil }, translation: { _ in nil }, guessesLinkCardDirections: true)

        try await waitUntil { GuessedWritingDirection.isKnown(title) && GuessedWritingDirection.isKnown(description) }
        #expect(GuessedWritingDirection.isRightToLeft(title))
        #expect(!GuessedWritingDirection.isRightToLeft(description))
    }

    /// 判定の結果はテストをまたいで覚えておくので、ほかのテストで判定済みにならないよう、文字を毎回変える。
    /// UUIDの英数字をそのまま足すと、言語の判定がその英数字に引っぱられ、アラビア語の文がルーマニア語などと判定されることがある。
    /// 16進の各字を、判定したい言語の16字に置き換えて足す。
    private func unique(in digits: String) -> String {
        let digits = Array(digits)
        return String(UUID().uuidString.compactMap { $0.hexDigitValue.map { digits[$0] } })
    }

    /// 長い文字は先頭だけで判定し、覚えておく表のほかの結果を追い出さない。
    @Test func longTextKeepsOtherGuesses() {
        let short = "こんにちは \(UUID().uuidString)"
        _ = GuessedWritingDirection.isRightToLeft(short)
        let long = String(repeating: "مرحبا بكم في موقعنا ", count: 20_000)

        #expect(GuessedWritingDirection.isRightToLeft(long))
        #expect(GuessedWritingDirection.isKnown(long))
        #expect(GuessedWritingDirection.isKnown(short))
    }

    /// 幅が決まる前のラベルでも、先に並べた幅で、長い本文を切るかを決める。
    /// 幅0のコンテナは幅を限らずに並べるので、1段落の長い本文を1行と数え、切らないと決めてしまう。
    @Test func truncationBeforeLayoutUsesPreparedWidth() async throws {
        let preparer = BodyTextPreparer()
        let builder = builder(preparer: preparer)
        let status = status("<p>\(String(repeating: "1段落だけの長い本文です。", count: 30))</p>")
        let truncation = try #require(BodyTruncation(threshold: 5, lines: 3))
        let style = label().textKitStyle
        let prepared = try await prepare(status, builder: builder, preparer: preparer, geometry: BodyTextPreparer.Geometry(style: style, width: width))
        let fresh = LinkLabel()
        fresh.numberOfLines = 0
        fresh.drawsWithTextKit = true
        fresh.truncation = truncation
        fresh.attributedText = prepared.text
        let layout = PreparedTextLayout(source: prepared.text, style: style, width: width, truncation: truncation)
        fresh.usePreparedLayout(layout)

        #expect(fresh.bounds.width == 0)
        #expect(fresh.isTruncatedByLength)
    }
}
