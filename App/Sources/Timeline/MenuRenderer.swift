import SciaCore
import UIKit

/// SciaCoreで組んだメニューの木（`MenuNode`）を、UIKitのメニューに描く。何をどの順に出すかは木が決め、ここでは描くだけにする。
/// 項目を押したら、その項目の操作を`perform`に渡す。
@MainActor
struct MenuRenderer<Command> {
    /// 押された項目の操作を行う。
    let perform: @MainActor (Command) -> Void
    /// 記号でないアイコン（人のアイコン、カスタム絵文字）の画像。nilを返したら、アイコンの記号を出す。
    var customIcon: @MainActor (MenuIcon) -> UIImage? = { _ in nil }

    init(perform: @escaping @MainActor (Command) -> Void, customIcon: @escaping @MainActor (MenuIcon) -> UIImage? = { _ in nil }) {
        self.perform = perform
        self.customIcon = customIcon
    }

    /// 木の根を、見出しを付けたメニューにする。見出しの名前が空なら、見出しを置かない。
    func menu(_ root: MenuNode<Command>) -> UIMenu {
        UIMenu(title: root.title, subtitle: root.subtitle, image: image(root.icon), children: elements(root.children))
    }

    func elements(_ nodes: [MenuNode<Command>]) -> [UIMenuElement] {
        nodes.map(element)
    }

    func element(_ node: MenuNode<Command>) -> UIMenuElement {
        switch node.content {
        case .action:
            return action(node)
        case .submenu(let children):
            return UIMenu(title: node.title, subtitle: node.subtitle, image: image(node.icon), children: elements(children))
        case .group(let children, let isRow):
            let menu = UIMenu(options: .displayInline, children: elements(children))
            if isRow { menu.preferredElementSize = .medium }
            return menu
        case .deferred(let load):
            // 読む間はUIKitの読み込み中の行を出す。
            return UIDeferredMenuElement.uncached { completion in
                Task { @MainActor in
                    completion(elements(await load()))
                }
            }
        }
    }

    /// 項目を描く。項目でないものは、押せない項目にする。
    func action(_ node: MenuNode<Command>) -> UIAction {
        var attributes: UIMenuElement.Attributes = []
        if !node.isEnabled { attributes.insert(.disabled) }
        if node.isDestructive { attributes.insert(.destructive) }
        let command = node.command
        return UIAction(title: node.title, subtitle: node.subtitle, image: image(node.icon), attributes: attributes, state: node.isSelected ? .on : .off) { [perform] _ in
            guard let command else { return }
            perform(command)
        }
    }

    func image(_ icon: MenuIcon?) -> UIImage? {
        guard let icon else { return nil }
        if case .symbol(let name) = icon {
            return UIImage(systemName: name)
        }
        return customIcon(icon) ?? icon.symbolName.flatMap { UIImage(systemName: $0) }
    }
}
