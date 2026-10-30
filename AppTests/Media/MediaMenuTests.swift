import SciaCore
import Testing
import UIKit
@testable import Scia

/// メディアのメニューを、設定の並びと、置く側が渡した動きから組むことを確かめる。決まりはdocs/menus.mdの「メディアのメニュー」にある。
@MainActor
struct MediaMenuTests {
    private func attachment(_ type: MediaAttachment.Kind, description: String? = nil) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: nil,
            description: description,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 640, height: 480))
        )
    }

    /// 一覧で長押ししたときのように、すべての動きを渡したメニュー。
    private func timelineMenu(for attachment: MediaAttachment, copied: (@MainActor (String) -> Void)? = nil) -> MediaMenu {
        var menu = MediaMenu(kind: attachment.type, attachment: attachment)
        menu.open = MediaMenu.Command {}
        menu.share = MediaMenu.Command {}
        menu.saveToPhotos = MediaMenu.Command {}
        menu.showAltText = MediaMenu.Command {}
        menu.fileURL = attachment.url
        menu.urlHandlers = URLMenuHandlers(linkBrowser: .external, copy: { _ in }, share: { _ in }, open: { _, _ in })
        menu.statusMenu = UIMenu(children: [UIAction(title: "返信") { _ in }])
        menu.copyValue = copied
        return menu
    }

    /// まとまりごとの項目の名前。サブメニューは`名前[中身]`で表す。
    private func outline(_ elements: [UIMenuElement]) -> [[String]] {
        elements.map { element in
            guard let group = element as? UIMenu, group.options.contains(.displayInline) else { return [describe(element)] }
            return group.children.map(describe)
        }
    }

    private func describe(_ element: UIMenuElement) -> String {
        guard let menu = element as? UIMenu else { return element.title }
        let children = menu.children.flatMap { child in (child as? UIMenu)?.options.contains(.displayInline) == true ? (child as? UIMenu)?.children ?? [] : [child] }
        return "\(menu.title)[\(children.map(describe).joined(separator: ","))]"
    }

    /// 既定の並びは、開く・共有・保存、読む、持ち出す、投稿の順にまとまりを分け、メディアの情報は「その他」に入れる。
    @Test func defaultMenuGroupsItemsByPurpose() {
        let elements = timelineMenu(for: attachment(.image, description: "夕焼け")).elements(layout: MediaMenuItem.defaultLayout)

        #expect(outline(elements) == [
            ["開く", "共有", "写真に保存"],
            ["代替テキスト"],
            ["リンクをコピー", "ブラウザで開く"],
            ["投稿[返信]"],
            ["その他[メディアの情報[640×480,PNG]]"],
        ])
    }

    /// 写真に入らない音声では保存を、代替テキストのないメディアでは代替テキストを出さない。
    @Test func omitsItemsThatDoNotApply() {
        let elements = timelineMenu(for: attachment(.audio)).elements(layout: MediaMenuItem.defaultLayout)
        let titles = outline(elements).flatMap(\.self)

        #expect(!titles.contains("写真に保存"))
        #expect(!titles.contains("代替テキスト"))
        #expect(titles.contains("共有"))
    }

    /// ビューアのように、開く動きと投稿のメニューを渡さなければ、その項目を出さない。開く項目は、URLを開く動きがなければ出さない。
    @Test func omitsItemsWithoutHandlers() {
        var menu = MediaMenu(kind: .image, attachment: attachment(.image))
        menu.share = MediaMenu.Command(isEnabled: false) {}
        menu.saveToPhotos = MediaMenu.Command(isEnabled: false) {}
        menu.fileURL = attachment(.image).url
        let elements = menu.elements(layout: MediaMenuItem.defaultLayout)

        #expect(outline(elements) == [["共有", "写真に保存"], ["その他[メディアの情報[640×480,PNG]]"]])
        let share = (elements.first as? UIMenu)?.children.first as? UIAction
        #expect(share?.attributes.contains(.disabled) == true)
    }

    /// 開く先のないビューア（Macの別のウィンドウや編集履歴から開いたとき）では、開く項目を出さず、リンクのコピーは残す。
    @Test func keepsCopyLinkWithoutOpeningURLs() {
        var menu = timelineMenu(for: attachment(.image))
        menu.opensURLs = false
        let titles = outline(menu.elements(layout: MediaMenuItem.defaultLayout)).flatMap(\.self)

        #expect(titles.contains("リンクをコピー"))
        #expect(!titles.contains("ブラウザで開く"))
    }

    /// 設定で隠した項目と、「その他」へ動かした項目は、その通りに出す。
    @Test func followsCustomizedLayout() {
        var elements = MediaMenuItem.defaultLayout.elements.compactMap { element -> MenuLayout<MediaMenuItem>.Element? in
            switch element {
            case .item(.open, _): .item(.open, isVisible: false)
            case .item(.share, _): nil
            default: element
            }
        }
        elements.append(.item(.share, isVisible: true))
        let menu = timelineMenu(for: attachment(.image)).elements(layout: MenuLayout(elements: elements))

        #expect(outline(menu).first == ["写真に保存"])
        #expect(!outline(menu).flatMap(\.self).contains("開く"))
        #expect(outline(menu).last == ["その他[メディアの情報[640×480,PNG],共有]"])
    }

    /// メディアの情報の行は、値を名前に、何の値かをサブタイトルに置き、押すと値をコピーする。
    @Test func infoRowCopiesItsValue() throws {
        var copied: [String] = []
        let elements = timelineMenu(for: attachment(.image)) { copied.append($0) }.elements(layout: MediaMenuItem.defaultLayout)
        let more = try #require(elements.last as? UIMenu)
        let group = try #require(more.children.first as? UIMenu)
        let info = try #require(group.children.first as? UIMenu)
        let resolution = try #require(info.children.first as? UIAction)

        #expect(resolution.title == "640×480")
        #expect(resolution.subtitle == "解像度")
        resolution.performWithSender(nil, target: nil)
        #expect(copied == ["640×480"])
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private final class Thumbnail: UIImageView, MediaViewerSource {}

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return UIWindow(windowScene: scene)
    }

    /// 一覧から共有を始めたあと、落としている間にサムネイルが別の投稿に使い回されても、共有シートには始めたときの画像を添え、
    /// 別の画像を出しているサムネイルを起点にしない。
    @Test func sharingFromMenuKeepsStartingPreviewWhenThumbnailIsReused() throws {
        let original = image(.red)
        let window = try makeWindow()
        let thumbnail = Thumbnail(image: image(.blue))
        window.addSubview(thumbnail)
        let file = URL(filePath: "/tmp/1.png")

        let content = MediaTransferCenter.menuShareSheet(file: file, startedWith: original, source: thumbnail)

        #expect((content.item as? MediaShareSheetItem)?.preview === original)
        #expect(content.anchor == nil)
    }

    /// 同じ画像を出しているサムネイルは、共有シートの起点にする。
    @Test func sharingFromMenuAnchorsToUnchangedThumbnail() throws {
        let original = image(.red)
        let window = try makeWindow()
        let thumbnail = Thumbnail(image: original)
        window.addSubview(thumbnail)

        let content = MediaTransferCenter.menuShareSheet(file: URL(filePath: "/tmp/1.png"), startedWith: original, source: thumbnail)

        #expect(content.anchor === thumbnail)
    }

    /// 持ち上げた画像の読み直しは、画面に収まる大きさに合わせ、ビューアと同じ上限を超えない。
    @Test func sharperImageFitsScreenAndViewerLimit() {
        let screen = CGSize(width: 390, height: 844)
        // 縦横比1:20の画像は、画面の幅のまま縦に長い大きさを渡すが、読むのは画面の高さに収まる大きさまで。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 390, height: 7800), within: screen, scale: 3) == 2532)
        // 画面に収まる大きさでも、ビューアの上限を超えない。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 2000, height: 1000), within: CGSize(width: 2000, height: 2000), scale: 3) == MediaImagePixelSize.full)
        // 画面に収まる横長の画像は、渡した大きさのまま読む。
        #expect(MediaMenuInteraction.sharperPixelSize(previewSize: CGSize(width: 390, height: 219), within: screen, scale: 3) == 1170)
    }
}
