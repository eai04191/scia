public import Foundation

/// メディアのメニューの項目を押したときの操作。
public enum MediaMenuCommand {
    case open
    case share
    case saveToPhotos
    case showAltText
    case translateText
    case url(URLMenuCommand)
    /// メディアの情報の行の値をコピーする。
    case copyValue(String)
    /// 「投稿」のサブメニューの、投稿のメニューの項目。
    indirect case status(StatusMenuCommand)
}

/// メディアのメニュー。一覧とビューアで、設定の同じ並びから組む。決まりはdocs/menus.mdの「メディアのメニュー」にある。
/// 項目ごとの動きは置く側が持ち、ここでは置く側が行えると言った項目だけを出す。
public struct MediaMenuTree {
    public let kind: MediaAttachment.Kind
    /// 代替テキストを見せる項目と、メディアの情報を組むのに使う。手元のファイルを開いたビューアではnil。
    public let attachment: MediaAttachment?
    /// 項目ごとに、置く側が行えるか。nilなら出さず、値は押せるか。ビューアでは、元のファイルが届くまで共有と保存を押せなくする。
    public var open: Bool?
    public var share: Bool?
    public var saveToPhotos: Bool?
    public var showAltText: Bool?
    public var translateText: Bool?
    /// リンクのコピーと開く項目で扱う、ファイルのURL。
    public var fileURL: URL?
    /// 開く場所の設定。nilなら、置く側がURLを扱えないので、URLの項目を出さない。
    public var linkBrowser: LinkBrowser?
    /// 開く項目を出すか。開く先のないビューア（Macの別のウィンドウや編集履歴から開いたとき）では、リンクのコピーだけを出す。
    public var opensURLs = true
    /// ビューアでファイルの中身から読んだ値。メディアの情報を詳しくする。一覧ではnil。
    public var details: MediaFileDetails?
    /// 投稿の投稿のメニューの中身。「投稿」のサブメニューにして出す。
    public var statusMenu: [MenuNode<StatusMenuCommand>]?

    public init(kind: MediaAttachment.Kind, attachment: MediaAttachment?) {
        self.kind = kind
        self.attachment = attachment
    }

    /// 出す項目がなければ空。
    @MainActor
    public func nodes(groups: MenuLayout<MediaMenuItem>.Groups) -> [MenuNode<MediaMenuCommand>] {
        groups.nodes { item in node(for: item).map { [$0] } ?? [] }
    }

    /// 見出しは置かない。長押ししたサムネイルを持ち上げて見せるので、何のメニューかは見れば分かるため。出す項目がなければnil。
    @MainActor
    public func menu(groups: MenuLayout<MediaMenuItem>.Groups) -> MenuNode<MediaMenuCommand>? {
        let children = nodes(groups: groups)
        return children.isEmpty ? nil : .submenu("", children)
    }

    /// 投稿のメニューの「カスタム絵文字」に並べる、絵文字の画像の`:shortcode:`のサブメニュー。出す項目がなければnil。
    /// アイコンには絵文字の画像を置き、出せなければ「カスタム絵文字」のアイコンを置く。
    @MainActor
    public func customEmojiSubmenu(_ emoji: CustomEmoji, groups: MenuLayout<MediaMenuItem>.Groups) -> MenuNode<MediaMenuCommand>? {
        guard let children = menu(groups: groups)?.children else { return nil }
        return .submenu(":\(emoji.shortcode):", icon: .customEmoji(emoji, fallbackSymbol: StatusMenuItem.customEmojis.symbolName), children)
    }

    @MainActor
    private func node(for item: MediaMenuItem) -> MenuNode<MediaMenuCommand>? {
        if let action = item.urlAction {
            guard let linkBrowser, action == .copyLink || opensURLs else { return nil }
            return action.node(url: fileURL, linkBrowser: linkBrowser).map(MediaMenuCommand.url)
        }
        switch item {
        case .open:
            return open.map { action(item, isEnabled: $0, .open) }
        case .share:
            return share.map { action(item, isEnabled: $0, .share) }
        case .saveToPhotos:
            guard [.image, .video, .gifv].contains(kind) else { return nil }
            return saveToPhotos.map { action(item, isEnabled: $0, .saveToPhotos) }
        case .altText:
            guard let description = attachment?.description, !description.isEmpty else { return nil }
            return showAltText.map { action(item, isEnabled: $0, .showAltText) }
        case .translateText:
            return translateText.map { action(item, isEnabled: $0, .translateText) }
        case .status:
            guard let statusMenu else { return nil }
            return .submenu(item.title, icon: .symbol(item.symbolName), statusMenu.map { $0.map(MediaMenuCommand.status) })
        case .info:
            return infoMenu(item)
        case .copyLink, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        }
    }

    private func action(_ item: MediaMenuItem, isEnabled: Bool, _ command: MediaMenuCommand) -> MenuNode<MediaMenuCommand> {
        .action(item.title, icon: .symbol(item.symbolName), isEnabled: isEnabled, command)
    }

    /// 値を名前にし、何の値かをサブタイトルに置いて、値を読みやすくする。押すと値をコピーする。
    private func infoMenu(_ item: MediaMenuItem) -> MenuNode<MediaMenuCommand>? {
        guard let attachment else { return nil }
        let lines = MediaInfo(attachment, details: details).lines
        guard !lines.isEmpty else { return nil }
        return .submenu(item.title, icon: .symbol(item.symbolName), lines.map { line in
            .action(line.value, subtitle: line.label, .copyValue(line.value))
        })
    }
}
