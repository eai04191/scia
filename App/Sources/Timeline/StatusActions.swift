import SciaCore
import UIKit

/// 投稿に対する操作。一覧では長押しのメニューから選ぶ。
enum StatusAction {
    case reply
    case favourite
    case reblog
}

extension TimelineViewController {
    /// 要素が指す投稿。通知なら対象の投稿。ギャップやフォローの通知などではnil。
    func status(for id: ItemID) -> Status? {
        switch entry(for: id) {
        case .status(let status), .pinned(let status): status
        case .notification(let notification): notification.status
        case .gap, nil: nil
        }
    }

    /// 長押しのメニューから開けるプロフィール。投稿なら投稿した人とブーストした人、通知なら操作した人と対象の投稿を書いた人。
    static func profileAccounts(of entry: TimelineEntry) -> [Account] {
        let accounts: [Account] = switch entry {
        case .status(let status), .pinned(let status): [status.displayed.account, status.account]
        case .notification(let notification): [notification.account] + (notification.status.map { [$0.displayed.account] } ?? [])
        case .gap: []
        }
        var seen: Set<Account.ID> = []
        return accounts.filter { seen.insert($0.id).inserted }
    }

    func profileAction(for account: Account) -> UIAction {
        UIAction(title: "@\(account.acct)のプロフィール", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
            self?.onOpenProfile?(account)
        }
    }

    func statusMenu(for status: Status) -> UIMenu {
        let shown = status.displayed
        let reply = UIAction(title: "返信", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.onStatusAction?(.reply, status)
        }
        let favourite = UIAction(
            title: shown.favourited ? "お気に入りを取り消す" : "お気に入り",
            image: UIImage(systemName: shown.favourited ? "star.slash" : "star")
        ) { [weak self] _ in
            self?.onStatusAction?(.favourite, status)
        }
        let reblog = UIAction(
            title: shown.reblogged ? "ブーストを取り消す" : "ブースト",
            image: UIImage(systemName: "arrow.2.squarepath"),
            attributes: canReblog(status) ? [] : .disabled
        ) { [weak self] _ in
            self?.onStatusAction?(.reblog, status)
        }
        return UIMenu(children: [reply, favourite, reblog])
    }

    private func canReblog(_ status: Status) -> Bool {
        guard let myAccountID else { return false }
        return status.canBeReblogged(by: myAccountID)
    }

    /// お気に入りとブーストの状態を、セルの右端にアイコンで出す。
    static func interactionAccessories(for status: Status?) -> [UICellAccessory] {
        guard let shown = status?.displayed else { return [] }
        let icons: [(String, UIColor, String)] = [
            shown.reblogged ? ("arrow.2.squarepath", .systemGreen, "ブースト済み") : nil,
            shown.favourited ? ("star.fill", .systemOrange, "お気に入り済み") : nil,
        ].compactMap(\.self)
        guard !icons.isEmpty else { return [] }
        let stack = UIStackView(arrangedSubviews: icons.map { name, color, label in
            let imageView = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)))
            imageView.tintColor = color
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = label
            return imageView
        })
        stack.axis = .vertical
        stack.spacing = 4
        return [.customView(configuration: .init(customView: stack, placement: .trailing(), reservedLayoutWidth: .actual))]
    }
}
