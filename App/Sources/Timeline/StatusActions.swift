import SciaCore
import UIKit

/// 投稿に対する操作。一覧では長押しのメニューから選ぶ。
enum StatusAction {
    case reply
    case favourite
    case reblog
    case editHistory
    case edit
    case delete
}

/// フォローリクエストへの返事。
enum FollowRequestDecision {
    case authorize
    case reject
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
    /// フォローリクエストの通知では、設定の並びの前に、承認と却下を設定によらず置く。
    /// 出す項目がなければnil。
    /// - Parameter id: メニューを出した要素。共有のシートを、その行から出す。
    func contextMenu(for entry: TimelineEntry, id: ItemID) -> UIMenu? {
        let status = Self.status(of: entry)
        let notifyingAccount: Account? = if case .notification(let notification) = entry { notification.account } else { nil }
        var shownUserIDs: Set<String> = []
        var children = settings.statusMenuLayout.groups.menuElements { item in
            elements(for: item, status: status, notifyingAccount: notifyingAccount, id: id, shownUserIDs: &shownUserIDs)
        }
        if case .notification(let notification) = entry, notification.type == .followRequest {
            children.insert(followRequestMenu(for: notification), at: 0)
        }
        return children.isEmpty ? nil : UIMenu(children: children)
    }

    private func followRequestMenu(for request: MastodonNotification) -> UIMenu {
        UIMenu(options: .displayInline, children: [
            UIAction(title: "承認", image: UIImage(systemName: "checkmark")) { [weak self] _ in
                self?.onFollowRequestDecision?(.authorize, request)
            },
            UIAction(title: "却下", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onFollowRequestDecision?(.reject, request)
            },
        ])
    }

    /// 同じユーザーが2つの項目に当たるときは、先に出る項目で1度だけ出す。
    private func elements(for item: StatusMenuItem, status: Status?, notifyingAccount: Account?, id: ItemID, shownUserIDs: inout Set<String>) -> [UIMenuElement] {
        func users(_ users: [MenuUser]) -> [UIMenuElement] {
            users.filter { shownUserIDs.insert($0.id).inserted }.compactMap { userElement(for: $0, id: id) }
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
        case .reply, .favourite, .reblog, .copyLink, .copyText, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .editHistory, .hideMedia, .systemTranslate, .edit, .delete:
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
        if let action = item.urlAction {
            return action.action(url: url, handlers: urlHandlers(id: id))
        }
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
        case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        case .editHistory:
            guard shown.editedAt != nil else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.onStatusAction?(.editHistory, status)
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
            guard !shown.mediaAttachments.isEmpty, mediaCover(for: status) == nil else { return nil }
            let isImageOnly = shown.mediaAttachments.allSatisfy { $0.type == .image }
            return UIAction(title: isImageOnly ? "画像を隠す" : item.title, image: item.image) { [weak self] _ in
                self?.hideMedia(of: shown)
            }
        case .copyText:
            guard let text = Self.plainText(of: shown) else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                UIPasteboard.general.string = text
                guard let self else { return }
                showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
            }
        case .systemTranslate:
            guard let text = Self.plainText(of: shown) else { return nil }
            return UIAction(title: item.title, image: item.image) { [weak self] _ in
                self?.translation.present(text)
            }
        case .notifyingUser, .author, .booster, .mentionedUsers:
            return nil
        }
    }

    /// コピーや翻訳に渡す本文。書式やリンクは落とし、文字だけにする。カスタム絵文字は`:shortcode:`のまま残す。
    /// 本文が空白だけならnil。
    private static func plainText(of status: Status) -> String? {
        let text = RichText.status(status).plainText
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }

    /// ユーザーのメニューを`@acct`のサブメニューにする。中身が1つで「その他」が空なら、サブメニューにせず直接並べる。
    /// 見出しはユーザー名だけにし、ほかのサーバーのユーザーならサーバー名をサブタイトルに出す。
    private func userElement(for user: MenuUser, id: ItemID) -> UIMenuElement? {
        let groups = settings.userMenuLayout.groups
        if groups.more.isEmpty, groups.main.count == 1, let only = groups.main.first, only.count == 1 {
            return userAction(only[0], for: user, id: id, inSubmenu: false)
        }
        let children = groups.menuElements { item in userAction(item, for: user, id: id, inSubmenu: true).map { [$0] } ?? [] }
        guard !children.isEmpty else { return nil }
        let parts = user.acct.split(separator: "@", maxSplits: 1)
        return UIMenu(
            title: "@\(parts.first ?? Substring(user.acct))",
            subtitle: parts.count == 2 ? String(parts[1]) : nil,
            image: UIImage(systemName: "person.crop.circle"),
            children: children
        )
    }

    private func userAction(_ item: UserMenuItem, for user: MenuUser, id: ItemID, inSubmenu: Bool) -> UIAction? {
        if let action = item.urlAction {
            return action.action(title: inSubmenu ? nil : Self.inlineTitle(of: action, for: user), url: user.url, handlers: urlHandlers(id: id))
        }
        switch item {
        case .profile:
            return UIAction(title: inSubmenu ? item.title : "@\(user.acct)のプロフィール", image: item.image) { [weak self] _ in
                switch user {
                case .account(let account): self?.onOpenProfile?(account)
                case .mention(let mention): self?.onOpenProfileID?(mention.id)
                }
            }
        case .copyLink, .share:
            // 共通の項目は、上で中身から組んだ。
            return nil
        }
    }

    /// サブメニューにせず投稿のメニューに直接並べるときの、ユーザーの共通の項目の名前。
    private static func inlineTitle(of action: URLMenuAction, for user: MenuUser) -> String {
        switch action {
        case .copyLink: "@\(user.acct)のリンクをコピー"
        case .share: "@\(user.acct)を共有"
        case .openInBrowser: "@\(user.acct)をブラウザで開く"
        case .openInDefaultBrowser: "@\(user.acct)を既定のブラウザで開く"
        case .openInAppSafari: "@\(user.acct)をアプリ内のSafariで開く"
        }
    }

    /// 共有のシートは、メニューを出した行から出す。
    private func urlHandlers(id: ItemID) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: settings.linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self) },
            share: { [weak self] url in self?.presentShareSheet(for: url, from: id) },
            open: { [weak self] url, browser in self?.openURL(url, in: browser) }
        )
    }

    /// メニューを出した行を起点にする。行が画面の外へ流れていれば一覧を起点にする。
    private func presentShareSheet(for url: URL, from id: ItemID) {
        let source = cell(for: id) ?? collectionView
        URLSharing.presentShareSheet(for: url, from: self) { $0.sourceItem = source }
    }

    private func canReblog(_ status: Status) -> Bool {
        guard let myAccountID else { return false }
        return status.canBeReblogged(by: myAccountID)
    }
}
