import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の絵文字ピッカー。
@MainActor
@Suite(.failureState, .scratch)
struct EmojiPaletteViewTests {
    /// 個人セットは、絵文字ピッカーを出している間に読み直したものが届いたら、その場で並べ直す。
    @Test func personalSetArrivingWhileShownReplacesTheSections() async throws {
        let sets = PersonalSets(["前のカテゴリー", "後のカテゴリー"])
        var sources = CompletionModel.Sources.unavailable
        sources.personalEmojiSet = { await sets.next() }
        let tuning = TuningStore(defaults: nil)
        let core = CompletionModel(sources: sources, settings: TuningCatalog.completionSettings(in: tuning))
        let completion = TextInputCompletion(completion: core, recentEmojis: nil, tuning: tuning, settings: AppDependencies.settings)
        let palette = EmojiPaletteView(emojiImages: .offline, thumbnailBuilder: nil)
        palette.frame = CGRect(x: 0, y: 0, width: 400, height: 400)

        completion.preparePalette()
        try await waitUntil { core.personalEmojiSet != nil }
        completion.updatePalette(palette, recentKeys: [])
        #expect(Self.sectionTitles(in: palette).contains("前のカテゴリー"))

        core.loadEmojisIfNeeded()
        try await waitUntil { core.personalEmojiSet?.categories.first?.name == "後のカテゴリー" }
        completion.updatePalette(palette, recentKeys: [])
        let titles = Self.sectionTitles(in: palette)
        #expect(titles.contains("後のカテゴリー") && !titles.contains("前のカテゴリー"), "まとまりのボタン: \(titles)")
    }

    /// 出している間に、個人セットの同じ絵文字の画像だけが変わったら、そのセルを新しい画像で描き直す。
    @Test func personalEmojiWithChangedImageIsRedrawn() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in png }
        let palette = EmojiPaletteView(emojiImages: store, thumbnailBuilder: nil)
        palette.frame = window.bounds
        window.addSubview(palette)
        let base = URL(filePath: "/")
        func sections(_ name: String) -> [EmojiPaletteSection] {
            let emoji = PaletteEmoji.custom(ServerEmoji(shortcode: "blob", url: base.appending(path: "\(name).gif"), staticUrl: base.appending(path: "\(name).png")))
            return [EmojiPaletteSection(kind: .personal(id: "a", name: "a"), emojis: [emoji], heading: .text("a"))]
        }
        palette.setContent(.sections(sections("old"), customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)
        try await waitUntil { Self.cells(in: collectionView).first.flatMap(Self.imageView(of:))?.image != nil }
        let drawn = Self.cells(in: collectionView).first.flatMap(Self.imageView(of:))?.image

        palette.setContent(.sections(sections("new"), customStatus: nil))
        try await waitUntil {
            collectionView.layoutIfNeeded()
            let image = Self.cells(in: collectionView).first.flatMap(Self.imageView(of:))?.image
            return image != nil && image !== drawn
        }
    }

    /// パレットを並べるたびに、チューニングの値をパレットに入れる。
    @Test func updatePaletteAppliesTuningValues() {
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(2, for: TuningCatalog.composeEmojiPaletteMaxSpan)
        tuning.setValue(0.5, for: TuningCatalog.composeEmojiPaletteMinimumHeightFraction)
        tuning.setValue(true, for: TuningCatalog.composeEmojiPaletteHardEdgeEffect)
        tuning.setValue(44, for: TuningCatalog.composeEmojiPaletteBarHeight)
        tuning.setValue(56, for: TuningCatalog.composeEmojiPaletteCellSize)
        tuning.setValue(160, for: TuningCatalog.composeEmojiPalettePreviewHeight)
        let core = CompletionModel(sources: .unavailable, settings: TuningCatalog.completionSettings(in: tuning))
        let completion = TextInputCompletion(completion: core, recentEmojis: nil, tuning: tuning, settings: AppDependencies.settings)
        let palette = EmojiPaletteView(emojiImages: .offline, thumbnailBuilder: nil)

        completion.updatePalette(palette, recentKeys: [])

        #expect(palette.maxSpan == 2)
        #expect(palette.minimumHeightFraction == 0.5)
        #expect(palette.hardEdgeEffect)
        #expect(palette.barHeight == 44)
        #expect(palette.cellSize == 56)
        #expect(palette.previewHeight == 160)
    }

    /// 長押しのメニューは、カスタム絵文字にだけ出す。Unicodeの絵文字の長押しは、肌の色の変更に空けておく。
    @Test func contextMenuIsOfferedOnlyForCustomEmojis() throws {
        let palette = EmojiPaletteView(emojiImages: .offline, thumbnailBuilder: nil)
        palette.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let base = URL(filePath: "/")
        let custom = PaletteEmoji.custom(ServerEmoji(shortcode: "blob", url: base.appending(path: "blob.gif"), staticUrl: base.appending(path: "blob.png")))
        let standard = PaletteEmoji.standard(StandardEmoji(emoji: "😀", name: "grinning", keywords: [], version: ""))
        palette.setContent(.sections([EmojiPaletteSection(kind: .uncategorized, emojis: [custom, standard], heading: .text("a"))], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)

        #expect(palette.collectionView(collectionView, contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 0)], point: .zero) != nil)
        #expect(palette.collectionView(collectionView, contextMenuConfigurationForItemsAt: [IndexPath(item: 1, section: 0)], point: .zero) == nil)
    }

    /// Unicodeの絵文字の長押しは、肌の色を変えられる絵文字にだけ出す。
    @Test func skinToneMenuIsOfferedOnlyForEmojisWithTones() throws {
        let palette = EmojiPaletteView(emojiImages: .offline, thumbnailBuilder: nil)
        palette.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let all = StandardEmojiCatalog.groups.flatMap(\.emojis)
        let thumbsUp = try #require(all.first { $0.emoji == "👍" })
        let grinning = try #require(all.first { $0.emoji == "😀" })
        palette.setContent(.sections([EmojiPaletteSection(kind: .standard("a"), emojis: [.standard(thumbsUp), .standard(grinning)])], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)

        #expect(palette.collectionView(collectionView, contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 0)], point: .zero) != nil)
        #expect(palette.collectionView(collectionView, contextMenuConfigurationForItemsAt: [IndexPath(item: 1, section: 0)], point: .zero) == nil)
    }

    /// 検索欄の隣のボタンで既定の肌の色を選ぶと、設定に残り、並びと補完の候補がその色になる。
    @Test(.scratch) func choosingDefaultSkinToneUpdatesThePaletteAndCompletion() throws {
        let tuning = TuningStore(defaults: nil)
        let settings = AppSettings(defaults: TestScratch.defaults("EmojiPaletteViewTests.skinTone"))
        let core = CompletionModel(sources: .unavailable, settings: TuningCatalog.completionSettings(in: tuning))
        let completion = TextInputCompletion(completion: core, recentEmojis: nil, tuning: tuning, settings: settings)
        let palette = EmojiPaletteView(emojiImages: .offline, thumbnailBuilder: nil)
        palette.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        completion.updatePalette(palette, recentKeys: [])
        func standardEmojis() -> [String] {
            guard case .sections(let sections, _) = palette.content else { return [] }
            return sections.flatMap(\.emojis).map(\.recentKey)
        }
        #expect(standardEmojis().contains("👍"))

        palette.onDefaultSkinToneChange(.dark)

        #expect(settings.emojiSkinTone == .dark)
        #expect(palette.defaultSkinTone == .dark)
        #expect(standardEmojis().contains("👍🏿") && !standardEmojis().contains("👍"))
        #expect(core.standardEmojiGroups().flatMap(\.emojis).contains { $0.emoji == "👍🏿" })
    }

    /// 持ち上げる絵は縦横比を保ち、パレットの幅を超える横長の絵文字は、幅に収まるまで高さごと縮める。
    @Test func previewOfWideEmojiShrinksToFitTheWidth() {
        let square = EmojiPalettePreviewController.contentSize(aspectRatio: 1, height: 120, maxWidth: 338)
        let wide = EmojiPalettePreviewController.contentSize(aspectRatio: 8, height: 120, maxWidth: 338)

        #expect(square == CGSize(width: 152, height: 152))
        #expect(wide.width == 338)
        #expect(abs((wide.width - 32) / (wide.height - 32) - 8) < 0.2)
    }

    private static func sectionTitles(in palette: EmojiPaletteView) -> [String] {
        palette.layoutIfNeeded()
        return descendants(of: palette).compactMap { ($0 as? UIButton)?.accessibilityLabel }
    }

    /// 画面に入る前に組み立てたセルも、画像が届いたら描き直し、画面に入ったときに画像で描く。
    /// 画面に見えているセルだけを描き直していたため、スクロールで先に組み立てたセルは、画像が届いても空のまま画面に出ていた。
    @Test func cellPreparedBeforeImageArrivesShowsTheImage() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let palette = EmojiPaletteView(emojiImages: store, thumbnailBuilder: nil)
        palette.frame = window.bounds
        window.addSubview(palette)
        let base = URL(filePath: "/")
        let emojis = (0..<400).map { index in
            let name = String(format: "emoji%03d", index)
            return PaletteEmoji.custom(ServerEmoji(shortcode: name, url: base.appending(path: "\(name).gif"), staticUrl: base.appending(path: "\(name).png")))
        }
        palette.setContent(.sections([EmojiPaletteSection(kind: .uncategorized, emojis: emojis)], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)

        // 画像が届く前にスクロールし、パレットに画面の下のセルを先に組み立てさせる。
        // パレットはスクロールが動いている間に、画面に入りそうなセルを先に組み立てる。
        let target = collectionView.contentOffset.y + 600
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        try await waitUntil { collectionView.contentOffset.y == target }

        gate.open()
        let urls = emojis.compactMap { emoji -> URL? in
            guard case .custom(let custom) = emoji else { return nil }
            // パレットは絵文字を動かすので、元の画像を読む。
            return custom.url
        }
        // パレットより後に登録したので、ここに知らせが届いたときには、パレットも描き直し終えている。
        var notified: Set<URL> = []
        store.addListener(owner: palette) { notified.formUnion($0) }
        // 毎回すべてを求める。`allSatisfy`で求めると最初の読めていないもので止まり、残りを待つたびに1つずつしか読みに行かない。
        try await waitUntil { urls.map { store.image(for: $0) }.allSatisfy { $0 != nil } && notified.isSuperset(of: urls) }

        collectionView.contentOffset.y += collectionView.bounds.height
        collectionView.layoutIfNeeded()
        let blank = Self.cells(in: collectionView).filter { Self.isVisible($0, in: collectionView) && Self.imageView(of: $0)?.image == nil }
        #expect(blank.isEmpty, "画像が届いたのに空のまま画面に出たセル: \(blank.compactMap(\.accessibilityLabel))")
    }

    /// 静止画がまだ届いていない絵文字は、小さい静止画で描き、静止画が届いたら差し替える。
    /// 速く流したときに、ファイルの読み出しや展開を待って枠が空いたまま見えないようにするため。
    @Test(.scratch) func drawsThumbnailUntilStillArrives() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }.pngData())
        let store = EmojiImageStore { _ in
            try await gate.wait()
            return png
        }
        let thumbnails = EmojiThumbnails(file: TestScratch.url("EmojiPaletteViewTests").appending(path: "thumbnails.bin"), pixelHeight: 8)
        let base = URL(filePath: "/")
        let emoji = ServerEmoji(shortcode: "blob", url: base.appending(path: "blob.gif"), staticUrl: base.appending(path: "blob.png"))
        thumbnails.add(emoji.url, image: try #require(UIImage(data: png)?.cgImage))
        try await waitUntil { thumbnails.contains(emoji.url) }
        let palette = EmojiPaletteView(emojiImages: store, thumbnails: thumbnails, thumbnailBuilder: nil)
        palette.frame = window.bounds
        window.addSubview(palette)
        palette.setContent(.sections([EmojiPaletteSection(kind: .uncategorized, emojis: [.custom(emoji)])], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)
        let cell = try #require(Self.cells(in: collectionView).first)

        #expect(Self.imageView(of: cell)?.image?.cgImage?.height == 8, "静止画が届く前は、小さい静止画で描く")

        gate.open()
        try await waitUntil { store.image(for: emoji.url) != nil && Self.imageView(of: cell)?.image?.cgImage?.height == 96 }
    }

    /// 描く画像がそろって組み立てたセルだけを、組み立て済みとみなす。パレットは、組み立て済みのセルを画面に入る直前に組み立て直さない。
    /// 小さい静止画で描いたセルや、枠の大きさが変わったセルは、組み立て直して届いた画像で描く。
    @Test func cellIsFinalOnlyWithItsImage() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in png }
        let base = URL(filePath: "/")
        let emoji = PaletteEmoji.custom(ServerEmoji(shortcode: "blob", url: base.appending(path: "blob.png"), staticUrl: base.appending(path: "blob_static.png")))
        let cell = EmojiPaletteCell(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        let requester = NSObject()
        func configure() {
            cell.configure(
                emoji, store: store, requester: requester,
                thumbnails: EmojiThumbnails(file: TestScratch.url("EmojiPaletteViewTests").appending(path: "thumbnails.bin"), pixelHeight: 8),
                glyphs: EmojiGlyphImageStore(),
                glyphArchive: EmojiGlyphArchive(directory: TestScratch.url("EmojiPaletteViewTests")) { 0 },
                emojiStyle: .system
            )
        }

        configure()
        #expect(!cell.isShowingFinalImage(of: emoji), "画像が届く前は組み立て済みとみなさない")
        guard case .custom(let custom) = emoji else { return }
        try await waitUntil { store.image(for: custom.url) != nil && store.hasFinishedLoadingAnimation(for: custom.url) }
        configure()
        #expect(cell.isShowingFinalImage(of: emoji))
        #expect(!cell.isShowingFinalImage(of: .custom(ServerEmoji(shortcode: "other", url: base.appending(path: "other.png"), staticUrl: base.appending(path: "other_static.png")))))
        cell.frame.size = CGSize(width: 96, height: 48)
        #expect(!cell.isShowingFinalImage(of: emoji), "枠の大きさが変われば組み立て直す")
    }

    /// Unicodeの絵文字は、画像ができるまで空けておき、できたら見えているセルに入れる。
    /// 文字として描いていたときは、セルを画面に出すフレームで絵を作り、速いスクロールでフレームが落ちた。
    @Test func standardEmojiAppearsWhenItsImageIsReady() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let gate = Gate()
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let glyphs = EmojiGlyphImageStore { _ in
            try? await gate.wait()
            return drawn
        }
        // 端末に置いたUnicodeの絵文字の画像を使わず、メモリの画像だけで描かせる。
        let palette = EmojiPaletteView(
            emojiImages: EmojiImageStore { _ in throw CancellationError() },
            glyphImages: glyphs,
            glyphArchive: EmojiGlyphArchive(directory: TestScratch.url("EmojiPaletteViewTests")) { 0 },
            thumbnailBuilder: nil
        )
        palette.frame = window.bounds
        window.addSubview(palette)
        let emojis = ["😀", "😃", "😄"].map { PaletteEmoji.standard(StandardEmoji(emoji: $0, name: $0, keywords: [], version: "1.0")) }
        palette.setContent(.sections([EmojiPaletteSection(kind: .standard("顔と感情"), emojis: emojis)], customStatus: nil))
        palette.layoutIfNeeded()
        let collectionView = try #require(Self.descendants(of: palette).compactMap { $0 as? UICollectionView }.first)
        let cells = Self.cells(in: collectionView)
        #expect(cells.count == emojis.count)
        #expect(cells.allSatisfy { Self.glyphView(of: $0)?.image == nil })

        gate.open()
        try await waitUntil { cells.allSatisfy { Self.glyphView(of: $0)?.image === drawn } }
    }

    /// 形だけのUnicodeの絵文字の画像（テンプレートの画像）は、今の外観の文字の色で塗り、色のある画像はそのままの色で描く。
    @Test func glyphViewTintsShapeWithLabelColor() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let square = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let view = EmojiPaletteGlyphView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        window.addSubview(view)
        let drawer = HierarchyDrawer()

        func centerColor(style: UIUserInterfaceStyle) throws -> UIColor {
            window.overrideUserInterfaceStyle = style
            window.backgroundColor = .clear
            view.layoutIfNeeded()
            let snapshot = drawer.image(of: view, scale: 2)
            var pixel: [UInt8] = [0, 0, 0, 0]
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(try #require(snapshot.cgImage), in: CGRect(x: -40, y: -40, width: 80, height: 80))
            return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
        }
        func components(_ color: UIColor) -> [CGFloat] {
            var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha].map { ($0 * 10).rounded() / 10 }
        }

        view.image = square
        #expect(components(try centerColor(style: .light)) == [1, 0, 0, 1], "色のある画像は、その色で描く")
        view.image = square.withRenderingMode(.alwaysTemplate)
        #expect(components(try centerColor(style: .light)) == components(UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))))
        #expect(components(try centerColor(style: .dark)) == components(UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))))
    }

    private static func glyphView(of cell: UICollectionViewCell) -> EmojiPaletteGlyphView? {
        cell.contentView.subviews.compactMap { $0 as? EmojiPaletteGlyphView }.first
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private static func cells(in collectionView: UICollectionView) -> [EmojiPaletteCell] {
        collectionView.subviews.compactMap { $0 as? EmojiPaletteCell }.filter { !$0.isHidden }
    }

    private static func isVisible(_ cell: UICollectionViewCell, in collectionView: UICollectionView) -> Bool {
        collectionView.bounds.intersects(cell.frame)
    }

    private static func imageView(of cell: UICollectionViewCell) -> UIImageView? {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first
    }
}

/// 読むたびに、次の名前のカテゴリーを1つ持つ個人セットを返す。
private actor PersonalSets {
    private var names: [String]

    init(_ names: [String]) {
        self.names = names
    }

    func next() -> PersonalEmojiSet? {
        let name = names.count > 1 ? names.removeFirst() : names.first ?? ""
        return PersonalEmojiSet(categories: [.init(id: name, name: name, entries: [.init(emoji: .standard(StandardEmoji(emoji: "👍", name: "サムズアップ", keywords: [], version: "")))])])
    }
}
