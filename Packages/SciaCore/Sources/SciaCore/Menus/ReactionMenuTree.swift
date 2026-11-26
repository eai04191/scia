import Foundation

/// 絵文字のリアクションのボタンのメニューの項目を選択したときの操作。
public enum ReactionMenuCommand: Equatable, Sendable {
    /// 付け外しする。trueなら付け、falseなら外す。
    case toggle(turningOn: Bool)
    /// その絵文字でリアクションした人のリストを開く。
    case openReactedBy
    /// カスタム絵文字の画像をビューアで開く。
    case open
    /// このメニューの並びの設定の画面を開く。
    case customize
}

/// 投稿の絵文字のリアクションのボタンのメニュー。決まりはdocs/emoji-reaction.mdの「リアクションのボタンのメニュー」にある。
/// 項目の名前、並び、出す条件、見出しはここだけが知る。選択したときの動き（ビューアや人のリストを開く先）は、出す場所が決める。
public struct ReactionMenuTree {
    public let reaction: EmojiReaction
    /// その絵文字でリアクションした人を読めるサーバーか。読めなければ「リアクションした人」を出さない。
    public let listsReactedAccounts: Bool

    public init(reaction: EmojiReaction, listsReactedAccounts: Bool = true) {
        self.reaction = reaction
        self.listsReactedAccounts = listsReactedAccounts
    }

    /// 見出し。絵文字（カスタム絵文字は`:shortcode:`）と数。
    public var title: String {
        let emoji = reaction.emoji
        let name = emoji.isCustom ? ":\(emoji.name):" : emoji.name
        return "\(name) \(reaction.displayedCount.formatted())"
    }

    /// 長押しで出すメニュー。見出しに絵文字と数を置く。出す項目がなければnil。
    @MainActor
    public func menu(groups: MenuLayout<ReactionMenuItem>.Groups) -> MenuNode<ReactionMenuCommand>? {
        let children = nodes(groups: groups)
        return children.isEmpty ? nil : .submenu(title, children)
    }

    @MainActor
    private func nodes(groups: MenuLayout<ReactionMenuItem>.Groups) -> [MenuNode<ReactionMenuCommand>] {
        groups.nodes { item -> [MenuNode<ReactionMenuCommand>] in
            switch item {
            case .toggle:
                return reaction.me
                    ? [.action("リアクションを外す", icon: .symbol("face.dashed"), .toggle(turningOn: false))]
                    : [.action("リアクションする", icon: .symbol(item.symbolName), .toggle(turningOn: true))]
            case .reactedBy:
                guard listsReactedAccounts else { return [] }
                return [.action(item.title, icon: .symbol(item.symbolName), .openReactedBy)]
            case .open:
                // 画像のあるカスタム絵文字でだけ出す。Unicodeの絵文字は画像がない。
                guard reaction.emoji.customEmoji != nil else { return [] }
                return [.action(item.title, icon: .symbol(item.symbolName), .open)]
            case .customize:
                return [.action(item.title, icon: .symbol(item.symbolName), .customize)]
            }
        }
    }
}
