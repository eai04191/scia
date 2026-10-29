import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 大きくした絵文字を、ラベルに実際に描かせて、描いた位置とレイアウトに使うベースラインを画素で比べる。
/// 文字のレイアウトから計算した枠では、ラベルが描く位置との食い違いに気づけないため。
@Suite(.scratch)
@MainActor
struct EmojiDrawingTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private struct Drawing {
        /// 色のある画素（絵文字）の上端と下端。ビューの上端からのpt。
        let colored: ClosedRange<CGFloat>
        /// 絵文字より右にある黒い画素（文字）の下端。ビューの上端からのpt。絵文字より右に文字がなければnil。
        let textBottom: CGFloat?
    }

    private func redEmoji() async throws -> (CustomEmoji, EmojiImageStore) {
        let url = try #require(URL(string: "https://example.social/emoji/red.png"))
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.pngData())
        let store = EmojiImageStore { _ in png }
        _ = store.image(for: url)
        try await waitUntil { store.image(for: url) != nil }
        return (CustomEmoji(shortcode: "red", url: url, staticUrl: url), store)
    }

    /// ビューを層ごと描き、色のある画素と、その右の黒い画素を探す。
    private func drawing(of view: UIView) throws -> Drawing {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        let bytes = try #require(CFDataGetBytePtr(cgImage.dataProvider?.data))
        func isColored(_ x: Int, _ y: Int) -> Bool {
            let pixel = y * cgImage.bytesPerRow + x * 4
            let channels = [bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]]
            return Int(channels.max() ?? 0) - Int(channels.min() ?? 0) > 64
        }
        func isBlack(_ x: Int, _ y: Int) -> Bool {
            let pixel = y * cgImage.bytesPerRow + x * 4
            return bytes[pixel] < 80 && bytes[pixel + 1] < 80 && bytes[pixel + 2] < 80
        }
        let rows = (0..<cgImage.height).filter { y in (0..<cgImage.width).contains { isColored($0, y) } }
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let right = (0..<cgImage.width).last { x in rows.contains { isColored(x, $0) } } ?? 0
        let textRows = (0..<cgImage.height).filter { y in ((right + 2)..<max(right + 2, cgImage.width)).contains { isBlack($0, y) } }
        return Drawing(colored: CGFloat(first)...CGFloat(last + 1), textBottom: textRows.last.map { CGFloat($0 + 1) })
    }

    enum Kind: String, CaseIterable {
        case custom, customLeading, unicode, unicodeTrailing
    }

    /// 大きくした絵文字は、ラベルの中で欠けず、ラベルが報告する最初のベースラインに文字が描かれる。
    /// 下げて描く絵文字が文字列の最初にあると、ラベルが絵文字のずらした位置をベースラインとして報告し、本文が上の部品に重なっていた。
    /// カスタム絵文字は、行の上に空きを残さない。
    @Test(arguments: [2.5, 4.0], Kind.allCases)
    func labelDrawsTextOnTheReportedBaseline(scale: Double, kind: Kind) async throws {
        let (red, store) = try await redEmoji()
        var renderer = RichTextRenderer(font: font, textColor: .black, emojiImages: store, language: "ja")
        renderer.emojiStyle = .system
        renderer.emojiScale = scale
        renderer.unicodeEmojiScale = scale
        let text = switch kind {
        case .custom: renderer.render(.plain("文:red:文", emojis: [red]))
        case .customLeading: renderer.render(.plain(":red:文", emojis: [red]))
        case .unicode: renderer.render(.plain("😀文", emojis: []))
        case .unicodeTrailing: renderer.render(.plain("文😀", emojis: []))
        }
        for label in [LinkLabel(), FadingLabel()] as [UILabel] {
            label.numberOfLines = label is FadingLabel ? 1 : 0
            label.attributedText = text
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
            label.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(label)
            let baseline = UILayoutGuide()
            parent.addLayoutGuide(baseline)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: parent.topAnchor),
                label.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                label.widthAnchor.constraint(equalToConstant: 360),
                baseline.topAnchor.constraint(equalTo: label.firstBaselineAnchor),
                baseline.heightAnchor.constraint(equalToConstant: 0),
            ])
            parent.layoutIfNeeded()
            let drawn = try drawing(of: label)
            let name = "\(type(of: label)) \(kind) scale=\(scale) drawn=\(drawn) baseline=\(baseline.layoutFrame.minY) height=\(label.bounds.height)"

            #expect(drawn.colored.lowerBound >= 0 && drawn.colored.upperBound <= label.bounds.height + 0.5, "\(name)")
            if let textBottom = drawn.textBottom {
                #expect(abs(textBottom - baseline.layoutFrame.minY) <= 1.5, "\(name)")
            }
            if kind == .custom || kind == .customLeading {
                #expect(drawn.colored.lowerBound <= 1, "行の上に空きがある: \(name)")
            }
        }
    }

    /// 名前と本文の絵文字を両方大きくしても、名前の行に描いた絵文字と本文に描いた絵文字が重ならず、名前の行の上にも空きを残さない。
    /// 時刻やハンドルを名前の絵文字より大きくしても、名前の行の上端は名前のラベルの上端のままなので（大きい部品は行の上へはみ出す）、名前の絵文字の上端をアイコンの上端に揃える。
    @Test(arguments: [2.5, 4.0], [false, true])
    func largeNameAndBodyEmojisDoNotOverlap(scale: Double, largeTimeAndHandle: Bool) async throws {
        let (red, store) = try await redEmoji()
        let settings = AppSettings.isolated()
        settings.emojiStyle = .system
        for item in [AppearanceCatalog.nameCustomEmojiScale, AppearanceCatalog.nameUnicodeEmojiScale, AppearanceCatalog.customEmojiScale, AppearanceCatalog.unicodeEmojiScale] {
            settings.setValue(scale, for: item)
        }
        if largeTimeAndHandle {
            settings.setValue(40, for: AppearanceCatalog.timeText)
            settings.setValue(40, for: AppearanceCatalog.nameSecondaryText)
        }
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let author = Account(id: "3", username: "carol", acct: "carol", displayName: ":red:名前😀", avatar: nil, emojis: [red])
        let post = Status(id: base.id, createdAt: base.createdAt, account: author, content: "<p>😀本文 :red: の絵文字</p>", spoilerText: "", url: nil, emojis: [red])
        let controller = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: store, avatarImages: .offline, settings: settings)
        let view = controller.contentConfiguration(for: post, base: .cell()).makeContentView()
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let name = try #require(subviews(of: FadingLabel.self, in: view).first { !$0.isHidden && ($0.attributedText?.length ?? 0) > 0 })
        let body = try #require(subviews(of: LinkLabel.self, in: view).first { !$0.isHidden })
        let avatar = try #require(subviews(of: AvatarView.self, in: view).first)
        func drawnInView(_ label: UILabel) throws -> ClosedRange<CGFloat> {
            let drawn = try drawing(of: label).colored
            let top = label.convert(CGPoint.zero, to: view).y
            return (drawn.lowerBound + top)...(drawn.upperBound + top)
        }
        let nameDrawn = try drawnInView(name)
        let bodyDrawn = try drawnInView(body)

        #expect(bodyDrawn.lowerBound - nameDrawn.upperBound >= settings.value(of: AppearanceCatalog.nameBodySpacing) - 1, "名前=\(nameDrawn) 本文=\(bodyDrawn)")
        if largeTimeAndHandle {
            let row = try #require(subviews(of: UIStackView.self, in: view).first { $0.arrangedSubviews.contains(name) })
            for part in row.arrangedSubviews.dropFirst() where !part.isHidden {
                #expect(part.convert(CGPoint.zero, to: view).y < nameDrawn.lowerBound, "時刻やハンドルが名前の絵文字より上へ伸びていない: \(part.frame) 名前=\(nameDrawn)")
            }
        }
        #expect(abs(nameDrawn.lowerBound - avatar.frame.minY) <= 1, "名前=\(nameDrawn) アイコン=\(avatar.frame)")
    }

    /// カスタム絵文字と絵文字は、割合が同じなら同じ高さに描き、割合を上げれば大きくなる。
    /// 基準は、絵文字を文字の大きさのまま描いたときの絵の高さ。Appleの絵文字は小さい文字ほど文字より大きめに描くため、
    /// 書体の大きさを割合どおりに変えるだけでは、1.0から1.1に上げても大きくならず、大きくしたときにカスタム絵文字より小さくなっていた。
    @Test(arguments: [EmojiStyle.system, .twemoji])
    func customAndUnicodeEmojisDrawAtTheSameHeight(style: EmojiStyle) async throws {
        let (red, store) = try await redEmoji()
        var previous: CGFloat = 0
        for scale in [0.5, 1.0, 1.1, 1.5, 2.0, 3.0] {
            var renderer = RichTextRenderer(font: font, textColor: .black, emojiImages: store, language: "ja")
            renderer.emojiStyle = style
            renderer.emojiScale = scale
            renderer.unicodeEmojiScale = scale
            func drawnHeight(_ text: RichText) throws -> CGFloat {
                let label = LinkLabel()
                label.numberOfLines = 0
                label.attributedText = renderer.render(text)
                label.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
                label.sizeToFit()
                let drawn = try drawing(of: label).colored
                return drawn.upperBound - drawn.lowerBound
            }
            // 「🟥」は、どちらの絵文字の書体でも、絵の枠いっぱいに描く。
            let custom = try drawnHeight(.plain(":red:", emojis: [red]))
            let unicode = try drawnHeight(.plain("🟥", emojis: []))

            #expect(abs(custom - unicode) <= 1.5, "\(style) scale=\(scale) カスタム絵文字=\(custom) 絵文字=\(unicode)")
            #expect(unicode > previous, "\(style) scale=\(scale) 絵文字=\(unicode) 前の割合=\(previous)")
            previous = unicode
        }
    }

    private func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview in [subview as? T].compactMap(\.self) + subviews(of: type, in: subview) }
    }
}
