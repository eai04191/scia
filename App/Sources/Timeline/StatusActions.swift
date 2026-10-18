import SciaCore
import UIKit

/// 投稿に対する操作。一覧では長押しのメニューから選ぶ。
enum StatusAction {
    case reply
    case favourite
    case reblog
    case edit
    case delete
}

extension TimelineViewController {
    /// 要素が指す投稿。通知なら対象の投稿。ギャップやフォローの通知などではnil。
    func status(for id: ItemID) -> Status? {
        entry(for: id).flatMap(Self.status(of:))
    }

    static func status(of entry: TimelineEntry) -> Status? {
        switch entry {
        case .status(let status), .pinned(let status): status
        case .notification(let notification): notification.status
        case .gap, .unreadable: nil
        }
    }

    /// 長押しのメニュー。並びは設定の投稿のメニューに従い、関係するユーザーはユーザーのメニューのサブメニューにする。決まりはdocs/menus.mdにある。
    /// 出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    func contextMenu(for entry: TimelineEntry, id: ItemID) -> UIMenu? {
        let status = Self.status(of: entry)
        let notifyingAccount: Account? = if case .notification(let notification) = entry { notification.account } else { nil }
        var shownUserIDs: Set<String> = []
        let children = menuElements(for: settings.statusMenuLayout.groups) { item in
            elements(for: item, status: status, notifyingAccount: notifyingAccount, id: id, shownUserIDs: &shownUserIDs)
        }
        return children.isEmpty ? nil : UIMenu(children: children)
    }

    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    private func menuElements<Item>(for groups: MenuLayout<Item>.Groups, elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        func inline(_ groups: [[Item]]) -> [UIMenuElement] {
            groups.compactMap { group in
                let children = group.flatMap(elements)
                return children.isEmpty ? nil : UIMenu(options: .displayInline, children: children)
            }
        }
        let main = inline(groups.main)
        let more = inline(groups.more)
        guard !more.isEmpty else { return main }
        return main + [UIMenu(title: "その他", image: UIImage(systemName: "ellipsis.circle"), children: more)]
    }

    /// 同じユーザーが2つの項目に当たるときは、先に出る項目で1度だけ出す。
    private func elements(for item: StatusMenuItem, status: Status?, notifyingAccount: Account?, id: ItemID, shownUserIDs: inout Set<String>) -> [UIMenuElement] {
        func users(_ users: [MenuUser]) -> [UIMenuElement] {
            users.filter { shownUserIDs.insert($0.id).inserted }.compactMap(userElement(for:))
        }
        switch item {
        case .notifyingUser:
            return users(notifyingAccount.map { [.account($0)] } ?? [])
        case .author:
            return users(status.map { [.account($0.displayed.account)] } ?? [])
        case .booster:
            guard let status, status.reblog != nil else { return [] }
            return users([.account(status.account)])
        case .mentionedUsers:
            return users(status?.displayed.mentions.map(MenuUser.mention) ?? [])
        case .reply, .favourite, .reblog, .copyLink, .share, .openInBrowser, .hideMedia, .edit, .delete:
            guard let status else { return [] }
            return statusAction(item, on: status, id: id).map { [$0] } ?? []
        }
    }

    /// 投稿への操作。ユーザーの項目は`userElement(for:)`で組むため、nilを返す。
    private func statusAction(_ item: StatusMenuItem, on status: Status, id: ItemID) -> UIAction? {
        let shown = status.displayed
        // `url`はMastodonのAPIでnullを取りうるため、ないときは押せないまま並べる。`uri`はActivityPubのIDで、ブラウザで開けるページとは限らないため代わりにしない。
        // ブーストなら元の投稿のページを指す。
        let url = shown.url
        let linkAttributes: UIMenuElement.Attributes = url == nil ? .disabled : []
        switch item {
        case .reply:
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.onStatusAction?(.reply, status)
            }
        case .favourite:
            return UIAction(
                title: shown.favourited ? "お気に入りを取り消す" : item.title,
                image: shown.favourited ? UIImage(systemName: "star.slash") : item.image
            ) { [weak self] _ in
                self?.onStatusAction?(.favourite, status)
            }
        case .reblog:
            return UIAction(
                title: shown.reblogged ? "ブーストを取り消す" : item.title,
                image: item.image,
                attributes: canReblog(status) ? [] : .disabled
            ) { [weak self] _ in
                self?.onStatusAction?(.reblog, status)
            }
        case .copyLink:
            return UIAction(title: item.title, image: item.image, attributes: linkAttributes) { [weak self] _ in
                guard let self, let url else { return }
                UIPasteboard.general.url = url
                showNotice(.linkCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            }
        case .share:
            return UIAction(title: item.title, image: item.image, attributes: linkAttributes) { [weak self] _ in
                guard let url else { return }
                self?.presentShareSheet(for: url, from: id)
            }
        case .openInBrowser:
            return UIAction(title: item.title, image: item.image, attributes: linkAttributes) { [weak self] _ in
                guard let url else { return }
                self?.onOpenLink?(.url(url), shown)
            }
        case .edit:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            // 投票の締め切りが近い投稿は、送り直すとサーバーが拒むので、押せないまま理由を添える。
            let canEdit = status.canBeEdited(now: Date())
            return UIAction(
                title: item.title,
                subtitle: canEdit ? nil : "締め切りまで5分を切った投票は編集できません",
                image: item.image,
                attributes: canEdit ? [] : .disabled
            ) { [weak self] _ in
                self?.onStatusAction?(.edit, status)
            }
        case .delete:
            guard let myAccountID, status.isAuthored(by: myAccountID) else { return nil }
            return UIAction(title: item.title, image: item.image, attributes: .destructive) { [weak self] _ in
                self?.onStatusAction?(.delete, status)
            }
        case .hideMedia:
            // 覆っている投稿では出さない。開くときは、閲覧注意と同じく覆いをタップする。
            guard !shown.mediaAttachments.isEmpty, mediaCovers.cover(for: shown) == nil else { return nil }
            let isImageOnly = shown.mediaAttachments.allSatisfy { $0.type == .image }
            return UIAction(title: isImageOnly ? "画像を隠す" : item.title, image: item.image) { [weak self] _ in
                self?.hideMedia(of: shown)
            }
        case .notifyingUser, .author, .booster, .mentionedUsers:
            return nil
        }
    }

    /// ユーザーのメニューを`@acct`のサブメニューにする。中身が1つで「その他」が空なら、サブメニューにせず直接並べる。
    private func userElement(for user: MenuUser) -> UIMenuElement? {
        let groups = settings.userMenuLayout.groups
        if groups.more.isEmpty, groups.main.count == 1, let only = groups.main.first, only.count == 1 {
            return userAction(only[0], for: user, inSubmenu: false)
        }
        let children = menuElements(for: groups) { item in [userAction(item, for: user, inSubmenu: true)] }
        guard !children.isEmpty else { return nil }
        return UIMenu(title: "@\(user.acct)", image: UIImage(systemName: "person.crop.circle"), children: children)
    }

    private func userAction(_ item: UserMenuItem, for user: MenuUser, inSubmenu: Bool) -> UIAction {
        switch item {
        case .profile:
            UIAction(title: inSubmenu ? item.title : "@\(user.acct)のプロフィール", image: item.image) { [weak self] _ in
                switch user {
                case .account(let account): self?.onOpenProfile?(account)
                case .mention(let mention): self?.onOpenProfileID?(mention.id)
                }
            }
        }
    }

    private func presentShareSheet(for url: URL, from id: ItemID) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPadとMacではポップオーバーで出るため、メニューを出した行を起点にする。行が画面の外へ流れていれば一覧を起点にする。
        activity.popoverPresentationController?.sourceItem = cell(for: id) ?? collectionView
        // アプリ内のSafariのシートを出したまま上の一覧から共有することがあるため、いちばん手前の画面から出す。
        frontmostPresented.present(activity, animated: true)
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
