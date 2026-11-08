import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// サーバーから来る極端な投稿で、セルの中身のビューが返す高さがUIKitの許す範囲に収まるかを測る。
/// UIKitは2777777ptを超える高さかNaNを返すと`_UIContentViewAssertValidFittingSize`で落とす。
@Suite(.scratch)
@MainActor
struct PostHeightProbeTests {
    private static let limit: CGFloat = 2_777_777

    private func emoji(width: CGFloat, height: CGFloat) async throws -> (CustomEmoji, EmojiImageStore<UIImage>) {
        let url = try #require(URL(string: "https://example.social/emoji/e.png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData())
        let store = EmojiImageStore { _ in png }
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        return (CustomEmoji(shortcode: "e", url: url, staticUrl: url), store)
    }

    private func measure(_ name: String, status: Status, emojiImages: EmojiImageStore<UIImage> = .offline) {
        let settings = AppSettings.isolated()
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: emojiImages, avatarImages: .offline, settings: settings)
        let configuration = timeline.contentConfiguration(for: status, base: .cell())
        for width: CGFloat in [375, 0] {
            let view = PostContentView(configuration: configuration)
            for target: CGFloat in [44, 10_000, 3_000_000] {
                let height = view.systemLayoutSizeFitting(CGSize(width: width, height: target), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
                print("PROBE \(name) width=\(width) target=\(target) height=\(height)")
                #expect(height.isFinite && height <= Self.limit, "\(name) width=\(width) target=\(target) height=\(height)")
            }
        }
    }

    private func status(name: String = "名前", content: String, spoiler: String = "", emojis: [CustomEmoji] = [], media: [MediaAttachment] = [], poll: Poll? = nil, card: PreviewCard? = nil) -> Status {
        let account = Account(id: "1", username: "a", acct: "a", displayName: name, avatar: nil, emojis: emojis)
        return Status(id: "100", createdAt: Date(timeIntervalSince1970: 1_800_000_000), account: account, content: content, spoilerText: spoiler, url: nil, emojis: emojis, mediaAttachments: media, poll: poll, card: card)
    }

    nonisolated private static let bodies: [(String, String)] = [
        ("empty", ""),
        ("emptyParagraph", "<p></p>"),
        ("spaces", "<p>   </p>"),
        ("breaks", "<p>" + String(repeating: "<br>", count: 3_000) + "</p>"),
        ("unbroken", "<p>" + String(repeating: "a", count: 20_000) + "</p>"),
        ("zalgo", "<p>a" + String(repeating: "\u{0301}", count: 5_000) + "</p>"),
        ("rtl", "<p>" + String(repeating: "مرحبا ", count: 500) + "</p>"),
        ("quote10", String(repeating: "<blockquote>", count: 10) + "<p>深い引用の本文です</p>" + String(repeating: "</blockquote>", count: 10)),
        ("quote60", String(repeating: "<blockquote>", count: 60) + "<p>深い引用の本文です</p>" + String(repeating: "</blockquote>", count: 60)),
        ("quote500", String(repeating: "<blockquote>", count: 500) + "<p>深い引用の本文です</p>" + String(repeating: "</blockquote>", count: 500)),
        ("list60", String(repeating: "<ul><li>", count: 60) + "項目" + String(repeating: "</li></ul>", count: 60)),
        ("list500", String(repeating: "<ul><li>", count: 500) + "項目" + String(repeating: "</li></ul>", count: 500)),
        ("code", "<pre><code>" + String(repeating: "x\n", count: 3_000) + "</code></pre>"),
    ]

    @Test(arguments: bodies.indices) func bodies(index: Int) {
        let (name, content) = Self.bodies[index]
        measure("body.\(name)", status: status(content: content))
        measure("spoiler.\(name)", status: status(content: content, spoiler: "注意"))
    }

    @Test(arguments: ["", " ", "\n\n\n", String(repeating: "長", count: 5_000), "a" + String(repeating: "\u{0301}", count: 2_000)])
    func names(name: String) {
        measure("name.\(name.count)", status: status(name: name, content: "<p>本文</p>"))
    }

    @Test(arguments: [(1.0, 4096.0), (4096.0, 1.0), (8192.0, 1.0), (1.0, 1.0)])
    func extremeEmoji(width: Double, height: Double) async throws {
        let (emoji, store) = try await emoji(width: width, height: height)
        measure("emoji.body.\(width)x\(height)", status: status(content: "<p>文:e:文</p>", emojis: [emoji]), emojiImages: store)
        measure("emoji.only.\(width)x\(height)", status: status(content: "<p>:e:</p>", emojis: [emoji]), emojiImages: store)
        measure("emoji.name.\(width)x\(height)", status: status(name: ":e:", content: "<p>本文</p>", emojis: [emoji]), emojiImages: store)
        measure("emoji.many.\(width)x\(height)", status: status(name: String(repeating: ":e:", count: 30), content: "<p>" + String(repeating: ":e:", count: 200) + "</p>", emojis: [emoji]), emojiImages: store)
    }

    @Test(arguments: [(0, 0), (1, 100_000), (100_000, 1), (Int.max, 1), (1, Int.max)])
    func extremeMedia(width: Int, height: Int) throws {
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: width, height: height))
        )
        measure("media.\(width)x\(height)", status: status(content: "<p>本文</p>", media: [attachment]))
        measure("media2.\(width)x\(height)", status: status(content: "", media: [attachment, attachment]))
    }

    @Test func polls() {
        let long = String(repeating: "長い選択肢", count: 400)
        for (name, options) in [("none", [String]()), ("empty", ["", ""]), ("long", [long, long]), ("many", (0..<200).map(String.init))] {
            let poll = Poll(id: "1", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: options.map { Poll.Option(title: $0, votesCount: 0) })
            measure("poll.\(name)", status: status(content: "<p>本文</p>", poll: poll))
        }
    }

    @Test func cards() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let long = String(repeating: "長いカードの題名", count: 500)
        for (name, title, width, height) in [("empty", "", 0, 0), ("long", long, 1, 100_000), ("wide", long, 100_000, 1)] {
            let card = PreviewCard(url: url, title: title, description: title, type: .link, providerName: title, image: url, width: width, height: height)
            measure("card.\(name)", status: status(content: "<p>本文</p>", card: card))
        }
    }

    /// 「投稿の見た目」の値を1つずつ、またはすべて上限と下限にして、添付ファイルとカードと投票のある投稿を測る。
    @Test func appearanceExtremes() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let attachment = MediaAttachment(id: "1", type: .image, url: url, previewUrl: url, meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900)))
        let card = PreviewCard(url: url, title: "題名", description: "説明", type: .link, providerName: "example", image: url, width: 400, height: 300)
        let poll = Poll(id: "1", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: [Poll.Option(title: "A", votesCount: 0), Poll.Option(title: "B", votesCount: 0)])
        let post = status(name: "とても長い名前を持っている人", content: "<p>本文の1行目です。</p><p>2段落目です。</p>", media: [attachment], poll: poll, card: card)
        let items = AppearanceCatalog.groups.flatMap(\.values)

        func height(_ change: (AppSettings) -> Void) -> CGFloat {
            let settings = AppSettings.isolated()
            change(settings)
            let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
            let view = PostContentView(configuration: timeline.contentConfiguration(for: post, base: .cell()))
            return view.systemLayoutSizeFitting(CGSize(width: 375, height: 3_000_000), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        }

        for item in items {
            for bound in [item.range.lowerBound, item.range.upperBound] {
                let measured = height { $0.setValue(bound, for: item) }
                print("PROBE appearance.\(item.id)=\(bound) width=375 height=\(measured)")
                #expect(measured.isFinite && measured <= Self.limit, "\(item.id)=\(bound) height=\(measured)")
            }
        }
        for (name, pick) in [("allLower", { (item: AppearanceValue) in item.range.lowerBound }), ("allUpper", { (item: AppearanceValue) in item.range.upperBound })] {
            let measured = height { settings in items.forEach { settings.setValue(pick($0), for: $0) } }
            print("PROBE appearance.\(name) width=375 height=\(measured)")
            #expect(measured.isFinite && measured <= Self.limit, "\(name) height=\(measured)")
        }
    }
}
