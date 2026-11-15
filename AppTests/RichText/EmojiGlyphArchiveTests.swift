import SciaCore
import SciaTesting
import Synchronization
import Testing
import UIKit
@testable import Scia

/// 絵文字ピッカーのUnicodeの絵文字の画像を、端末に置いて持つ仕組み。
@MainActor
@Suite(.failureState, .scratch)
struct EmojiGlyphArchiveTests {
    /// スイートはテストごとに作られるので、テストごとに別の場所になる。
    private let directory = TestScratch.url("EmojiGlyphArchiveTests")

    private static let geometry = EmojiGlyphArchive.Geometry(
        pointSize: 28, width: 40, height: 40, scale: 2, style: .twemoji, systemVersion: EmojiGlyphArchive.systemVersion
    )

    private func makeArchive(capacity: Int?) -> EmojiGlyphArchive {
        EmojiGlyphArchive(directory: directory) { capacity }
    }

    /// 空きが足りれば、描く大きさの画像も作り、端末に置いた画像を描く大きさで返す。起動し直しても読める。
    @Test func buildsFullImagesWithRoom() async throws {
        let archive = makeArchive(capacity: Int.max)
        archive.use(Self.geometry)

        await archive.build(["😀"])

        // 小さい画像と描く大きさの画像は、別々に書くので、描く大きさの画像が入るまで待つ。
        let glyph = try #require(await waitForGlyph("😀", in: archive) { $0.isFull })
        #expect(glyph.isFull)
        #expect(glyph.image.height == Self.geometry.pixelHeight)
        await archive.flush()
        let reopened = makeArchive(capacity: Int.max)
        reopened.loadStoredGeometry(style: .twemoji)
        #expect(reopened.glyph(for: "😀", geometry: Self.geometry)?.isFull == true)
    }

    /// 空きが足りなければ、小さい画像だけを作る。
    @Test func buildsOnlySmallImagesWithoutRoom() async throws {
        let archive = makeArchive(capacity: 0)
        archive.use(Self.geometry)

        await archive.build(["😀"])

        let glyph = try #require(await waitForGlyph("😀", in: archive))
        #expect(!glyph.isFull)
        #expect(glyph.image.height == EmojiGlyphArchive.smallPixelHeight)
    }

    /// 描く大きさか絵が変わったら、前の画像は使わず、置いた画像を消して作り直す。
    @Test func discardsImagesWhenGeometryChanges() async throws {
        let archive = makeArchive(capacity: Int.max)
        archive.use(Self.geometry)
        await archive.build(["😀"])
        _ = await waitForGlyph("😀", in: archive) { $0.isFull }
        await archive.flush()

        var changed = Self.geometry
        changed.style = .system
        archive.use(changed)

        #expect(archive.glyph(for: "😀", geometry: changed) == nil)
        #expect(archive.glyph(for: "😀", geometry: Self.geometry) == nil)
        let reopened = makeArchive(capacity: Int.max)
        reopened.loadStoredGeometry(style: .twemoji)
        #expect(reopened.glyph(for: "😀", geometry: Self.geometry) == nil, "絵文字の絵の設定が違うので読まない")
    }

    /// 裏で作る側は、絵文字ピッカーが記録した大きさがあればそれを使い、なければ自分で計算した大きさを使う。
    /// 画面の倍率の違う画面にシーンが複数あると、計算した大きさが絵文字ピッカーのものと食い違い、互いの画像を消し合うため。
    @Test func prefersGeometryRecordedByPalette() {
        makeArchive(capacity: Int.max).use(Self.geometry)

        let reopened = makeArchive(capacity: Int.max)
        #expect(reopened.loadStoredGeometry(style: .twemoji))
        #expect(makeArchive(capacity: Int.max).loadStoredGeometry(style: .system) == false, "絵文字の絵の設定が違えば、記録した大きさは使わない")
    }

    /// 描く大きさを切り替えて戻っても、前に作った画像は、起動し直したあとも読める。
    /// 切り替えたときに前のフォルダーを消すと、戻ったときに使い回す書き手が書いたつもりの画像が残らないため。
    @Test func keepsImagesAfterSwitchingBack() async throws {
        let archive = makeArchive(capacity: Int.max)
        archive.use(Self.geometry)
        await archive.build(["😀"])
        _ = await waitForGlyph("😀", in: archive) { $0.isFull }
        await archive.flush()

        var changed = Self.geometry
        changed.style = .system
        archive.use(changed)
        archive.use(Self.geometry)

        let reopened = makeArchive(capacity: Int.max)
        reopened.loadStoredGeometry(style: .twemoji)
        #expect(reopened.glyph(for: "😀", geometry: Self.geometry)?.isFull == true)
    }

    /// 文字として描かれる絵文字（twemojiの「©」）は、外観で色が変わるので、形だけで持つ。色の付いた絵文字は、色のまま持つ。
    @Test func keepsTextGlyphsAsShape() async throws {
        let archive = makeArchive(capacity: Int.max)
        archive.use(Self.geometry)

        await archive.build(["©", "😀"])

        #expect(try #require(await waitForGlyph("©", in: archive)).isShape)
        #expect(try #require(await waitForGlyph("😀", in: archive)).isShape == false)
    }

    /// 絵文字ピッカーに並ぶどの絵文字も、ライトとダークで絵が変わるのは、形だけと判定したものに限る。
    /// 外観で変わる絵文字を色のまま持つと、外観を切り替えたときに前の外観の色で出るため。
    @Test(arguments: EmojiStyle.allCases) func onlyShapesChangeWithAppearance(style: EmojiStyle) async throws {
        var geometry = Self.geometry
        geometry.style = style
        var changed: [String] = []
        var shapes: [String] = []
        for emoji in StandardEmojiAvailability.groups(for: style).flatMap(\.emojis) {
            func render(_ userInterfaceStyle: UIUserInterfaceStyle) async -> CGImage? {
                await EmojiGlyphImageStore.draw(EmojiGlyphImageStore.Request(
                    text: emoji.emoji, pointSize: geometry.pointSize, style: style, width: geometry.width, height: geometry.height, scale: geometry.scale, userInterfaceStyle: userInterfaceStyle
                )).cgImage
            }
            let light = try #require(await render(.light))
            let dark = try #require(await render(.dark))
            if Self.pixels(light) != Self.pixels(dark) {
                changed.append(emoji.emoji)
            }
            if EmojiGlyphArchive.isShape(light) {
                shapes.append(emoji.emoji)
            }
        }
        #expect(changed == shapes)
    }

    private static func pixels(_ image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.data.map { Data(bytes: $0, count: image.width * image.height * 4) }
    }

    /// 足すのは裏で書くので、引けるようになるまで待つ。
    private func waitForGlyph(
        _ text: String, in archive: EmojiGlyphArchive, until condition: (EmojiGlyphArchive.Glyph) -> Bool = { _ in true }
    ) async -> EmojiGlyphArchive.Glyph? {
        try? await waitUntil { archive.glyph(for: text, geometry: Self.geometry).map(condition) == true }
        return archive.glyph(for: text, geometry: Self.geometry)
    }
}
