/// カスタム絵文字のメニューの項目を押したときの操作。
public enum CustomEmojiMenuCommand {
    /// `:shortcode:`の文字をコピーする。
    case copyShortcode(String)
    /// 絵文字の描き方を変える。
    case setDisplay(CustomEmojiDisplay)
    case open
    case share
    case saveToPhotos
    case url(URLMenuCommand)
    /// メディアの情報の行の値をコピーする。
    case copyValue(String)
    /// このメニューの並びの設定の画面を開く。
    case customize
}

/// カスタム絵文字のメニュー。投稿のメニューとプロフィールの文章のメニューの「カスタム絵文字」と、絵文字のパレットの長押しで、設定の同じ並びから組む。
/// 決まりはdocs/menus.mdの「カスタム絵文字のメニュー」にある。
/// 項目ごとの動きは置く側が持ち、ここでは置く側が行えると言った項目だけを出す。
public struct CustomEmojiMenuTree {
    public let emoji: CustomEmoji
    /// 項目ごとに、置く側が行えるか。falseなら出さない。
    public var open = false
    public var share = false
    public var saveToPhotos = false
    /// 開く場所の設定。nilなら、置く側がURLを扱えないので、URLの項目を出さない。
    public var linkBrowser: LinkBrowser?
    /// 開く項目を出すか。開く先のない置き場所では、リンクのコピーだけを出す。
    public var opensURLs = true
    /// 今の描き方。nilなら、置く側が描き方を変えられないので、「表示」を出さない。
    public var display: CustomEmojiDisplay?
    /// 元の画像を読んで、動かさないと分かったか。分かっていれば、「表示」に動きだけを変える選択肢を出さない。
    public var isKnownStill = false

    public init(emoji: CustomEmoji) {
        self.emoji = emoji
    }

    /// 出す項目がなければ空。
    @MainActor
    public func nodes(groups: MenuLayout<CustomEmojiMenuItem>.Groups) -> [MenuNode<CustomEmojiMenuCommand>] {
        groups.nodes { item in node(for: item).map { [$0] } ?? [] }
    }

    /// 絵文字のパレットで、長押しした絵文字を持ち上げた下に出すメニュー。
    /// 見出しは置かない。何の絵文字かは、持ち上げた絵と、「ショートコードをコピー」の項目に出す`:shortcode:`で分かるため。
    @MainActor
    public func menu(groups: MenuLayout<CustomEmojiMenuItem>.Groups) -> MenuNode<CustomEmojiMenuCommand> {
        .submenu("", nodes(groups: groups))
    }

    /// ほかのメニューの「カスタム絵文字」に並べる、`:shortcode:`のサブメニュー。出す項目がなければnil。
    /// アイコンには絵文字の画像を置き、出せなければ「カスタム絵文字」のアイコンを置く。
    @MainActor
    public func submenu(groups: MenuLayout<CustomEmojiMenuItem>.Groups) -> MenuNode<CustomEmojiMenuCommand>? {
        let children = nodes(groups: groups)
        guard !children.isEmpty else { return nil }
        return .submenu(shortcodeText, icon: .customEmoji(emoji, fallbackSymbol: StatusMenuItem.customEmojis.symbolName), children)
    }

    /// 投稿に書ける形のショートコード。
    private var shortcodeText: String { ":\(emoji.shortcode):" }

    @MainActor
    private func node(for item: CustomEmojiMenuItem) -> MenuNode<CustomEmojiMenuCommand>? {
        if let action = item.urlAction {
            guard let linkBrowser, action == .copyLink || opensURLs else { return nil }
            return action.node(url: emoji.url, linkBrowser: linkBrowser).map(CustomEmojiMenuCommand.url)
        }
        switch item {
        case .copyShortcode:
            // メディアの情報の行と同じく、コピーする文字を名前にし、項目の名前をサブタイトルに置く。項目の名前を名前にすると、メニューの幅で2行に折り返すため。
            return .action(shortcodeText, subtitle: item.title, icon: .symbol(item.symbolName), .copyShortcode(shortcodeText))
        case .display:
            guard let display else { return nil }
            return .submenu(item.title, subtitle: display.title, icon: .symbol(item.symbolName), CustomEmojiDisplay.choices(isKnownStill: isKnownStill, current: display).map { choice in
                .action(choice.title, isSelected: choice == display, .setDisplay(choice))
            })
        case .open:
            return open ? action(item, .open) : nil
        case .share:
            return share ? action(item, .share) : nil
        case .saveToPhotos:
            return saveToPhotos ? action(item, .saveToPhotos) : nil
        case .info:
            return infoMenu(item)
        case .customize:
            return action(item, .customize)
        case .copyLink, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        }
    }

    private func action(_ item: CustomEmojiMenuItem, _ command: CustomEmojiMenuCommand) -> MenuNode<CustomEmojiMenuCommand> {
        .action(item.title, icon: .symbol(item.symbolName), command)
    }

    /// メディアのメニューの「メディアの情報」と同じく、値を名前にし、何の値かをサブタイトルに置く。押すと値をコピーする。
    private func infoMenu(_ item: CustomEmojiMenuItem) -> MenuNode<CustomEmojiMenuCommand>? {
        let lines = MediaInfo(emoji.attachment, details: nil).lines
        guard !lines.isEmpty else { return nil }
        return .submenu(item.title, icon: .symbol(item.symbolName), lines.map { line in
            .action(line.value, subtitle: line.label, .copyValue(line.value))
        })
    }
}
