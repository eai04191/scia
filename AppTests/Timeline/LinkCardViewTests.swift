import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct LinkCardViewTests {
    private func layout(descriptionLines: Int, showsSite: Bool = true) throws -> (view: LinkCardView, frames: AppearancePreviewFrames) {
        let url = try #require(URL(string: "https://example.com/article"))
        let card = PreviewCard(
            url: url,
            title: "記事のタイトル",
            description: "ストリーミングAPIに対応した、手触りの良いiOS向けMastodonクライアント。日本語と英字が混ざった長い説明",
            type: .link,
            providerName: "Example",
            image: nil
        )
        let view = LinkCardView(store: .offline)
        view.apply(LinkCardView.Content(
            card: .card(card),
            padding: 10,
            transitionDuration: 0,
            thumbnailSide: .left,
            typography: .standard,
            showsSite: showsSite,
            descriptionLines: descriptionLines,
            lineSpacing: 2
        ))
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 328, height: 400))
        container.addSubview(view)
        view.frame = CGRect(origin: .zero, size: CGSize(width: 328, height: view.intrinsicContentSize.height))
        view.layoutIfNeeded()
        return (view, view.textPreviewFrames(in: view))
    }

    /// 説明を2行にすると、長い説明は2行で描き、1行のときより背が高い。
    @Test func descriptionUsesConfiguredLines() throws {
        let one = try layout(descriptionLines: 1)
        let two = try layout(descriptionLines: 2)
        let lineHeight = PostTypography.standard.font(.linkCardDetail).lineHeight
        let description = try #require(two.frames[.cardDescription]?.first)
        #expect(description.height > lineHeight * 1.5)
        // 枠が足りないと、UILabelは収まる行だけを描く。日本語の代わりの書体は行が高いので、2行目が枠に収まっていることを確かめる。
        let label = try #require(two.view.descriptionLabelForTesting)
        #expect(linesFitting(in: label) == 2)
        #expect(two.view.intrinsicContentSize.height > one.view.intrinsicContentSize.height)
    }

    /// 説明を0行にするとサイト名も出さずに済むほど背が低くなり、説明の枠はなくなる。
    @Test func hidesDescriptionAndSite() throws {
        let full = try layout(descriptionLines: 1)
        let compact = try layout(descriptionLines: 0, showsSite: false)
        #expect(compact.frames[.cardDescription] == nil)
        #expect(compact.view.intrinsicContentSize.height < full.view.intrinsicContentSize.height)
    }

    /// ラベルの枠の高さに収まる行の数。UILabelと同じく、収まらない行は数えない。
    private func linesFitting(in label: UILabel) -> Int {
        let storage = NSTextStorage(string: label.text ?? "", attributes: [.font: label.font as Any])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        manager.addTextContainer(container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in count += 1 }
        return count
    }
}
