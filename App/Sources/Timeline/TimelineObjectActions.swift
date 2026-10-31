import SciaCore
import UIKit

/// 一覧の行と、行の中の部品のタップと長押し。決まりはdocs/object-actions.mdにある。
extension TimelineViewController {
    func installRowObjectActions() {
        touchRecorder.cancelsTouchesInView = false
        touchRecorder.delaysTouchesEnded = false
        collectionView.addGestureRecognizer(touchRecorder)
        rowLongPress = ObjectLongPress(on: collectionView, accepts: { [weak self] location in
            // 投稿を選んでいる間は、長押しに割り当てた操作も行わない。行は選ぶか外すかだけにする。
            guard let self, !isSelectingPosts, let indexPath = collectionView.indexPathForItem(at: location) else { return false }
            return rowTarget(at: indexPath)?.performsLongPress() ?? false
        }, perform: { [weak self] location in
            guard let self, let indexPath = collectionView.indexPathForItem(at: location) else { return }
            rowTarget(at: indexPath)?.perform(.longPress, in: collectionView, at: location)
        })
    }

    /// 行の対象。投稿、通知、人の一覧の行で、ほかの行（ギャップ、読めなかった行）ではnil。
    func rowTarget(at indexPath: IndexPath) -> (any ObjectActionTarget)? {
        guard let id = itemID(at: indexPath), let entry = entry(for: id) else { return nil }
        switch entry {
        case .status(let status), .pinned(let status):
            return rowStatusTarget(.status, entry: entry, id: id, opening: status)
        case .notification(let notification):
            return rowStatusTarget(.notification, entry: entry, id: id, opening: notification.status)
        case .account(let account):
            return userTarget(for: account, id: id)
        case .notificationRequest(let request):
            return NotificationRequestTarget(
                open: { [weak self] in self?.onOpenNotificationRequest?(request) },
                buildMenu: { [weak self] in self?.contextMenu(for: entry, id: id) },
                lifecycle: rowMenuLifecycle
            )
        case .gap, .unreadable, .search:
            return nil
        }
    }

    /// 投稿と通知の行。主な操作は、行のスレッドを開く。開けない行（スレッドの中心の投稿、投稿のない通知）では行えない。
    private func rowStatusTarget(_ entity: ObjectEntity<StatusMenuItem>, entry: TimelineEntry, id: ItemID, opening status: Status?) -> ObjectTarget<StatusMenuItem, StatusMenuCommand> {
        ObjectTarget(
            entity: entity,
            settings: settings,
            primaryIsAvailable: status.map(canOpenThread(of:)) ?? false,
            primary: { [weak self] _ in
                guard let self, let status, canOpenThread(of: status) else { return }
                recordOpenThread()
                onOpenThread?(status, rowFrame(of: id))
            },
            buildMenu: { [weak self] groups in self?.statusMenu(for: entry, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// ユーザー。人の一覧の行と、行の中のアイコンや「〜がブースト」の行。長押しの既定は、その人のユーザーのメニュー。
    func userTarget(for account: Account, id: ItemID) -> ObjectTarget<UserMenuItem, UserMenuCommand> {
        ObjectTarget(
            entity: .user,
            settings: settings,
            primaryIsAvailable: onOpenProfile != nil,
            primary: { [weak self] _ in self?.onOpenProfile?(account) },
            buildMenu: { [weak self] groups in self?.builtUserMenu(for: .account(account), id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// 引用の囲み。対象は引用元の投稿で、メニューは引用元の投稿の投稿のメニュー。
    /// - Parameter openThread: 主な操作（スレッドを開く）で行う、今のタップの処理。押した囲みを渡す。
    func statusTarget(for status: Status, id: ItemID, openThread: @escaping (UIView) -> Void) -> ObjectTarget<StatusMenuItem, StatusMenuCommand> {
        let entry = TimelineEntry.status(status)
        return ObjectTarget(
            entity: .status,
            settings: settings,
            primary: openThread,
            buildMenu: { [weak self] groups in self?.statusMenu(for: entry, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// リンクカード。対象はリンクで、メニューはリンクのメニュー。
    /// - Parameter open: 主な操作（ブラウザで開く）で行う、今のタップの処理。
    func linkTarget(for url: URL, id: ItemID, open: @escaping () -> Void) -> ObjectTarget<LinkMenuItem, LinkMenuCommand> {
        ObjectTarget(
            entity: .link,
            settings: settings,
            primary: { _ in open() },
            buildMenu: { [weak self] groups in self?.builtLinkMenu(for: url, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// Xの投稿の囲みのような、ほかのサービスの投稿。
    /// - Parameters:
    ///   - url: 元の投稿のURL。
    ///   - text: コピーや翻訳に渡す本文。本文がなければnil。
    ///   - open: 主な操作（ブラウザで開く）で行う、今のタップの処理。
    func externalPostTarget(url: URL, text: String?, id: ItemID, open: @escaping () -> Void) -> ObjectTarget<ExternalPostMenuItem, ExternalPostMenuCommand> {
        ObjectTarget(
            entity: .externalPost,
            settings: settings,
            primary: { _ in open() },
            buildMenu: { [weak self] groups in self?.builtExternalPostMenu(url: url, text: text, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// 行の中から出したメニューを開いている間と閉じたあと。長押しのメニューと同じく、開いている間は一覧を動かさず、メニューに出る人のアイコンを読む。
    var rowMenuLifecycle: MenuLifecycle {
        MenuLifecycle(
            willShow: { [weak self] in
                guard let self else { return }
                UserAction.openMenu(screen: screenName).record()
                menuWillShow()
                contextMenuIcons.menuWillAppear(in: view.window)
            },
            willEnd: { [weak self] in self?.contextMenuIcons.menuWillEnd() },
            didHide: { [weak self] in self?.menuDidHide() }
        )
    }
}

/// 保留中の通知の行。タップでその人からの通知を開き、長押しで「受け入れる」「無視」とユーザーのメニューを出す。
/// どちらも並びの設定に載せない固定の操作なので、タップと長押しの設定には従わない。決まりはdocs/notification-filter.mdにある。
@MainActor
private struct NotificationRequestTarget: ObjectActionTarget {
    let open: () -> Void
    let buildMenu: () -> UIMenu?
    let lifecycle: MenuLifecycle

    func menu() -> UIMenu? {
        buildMenu()
    }

    var acceptsTap: Bool { true }

    /// 長押しは、一覧の長押しのメニューで出す。
    func performsLongPress() -> Bool { false }

    func perform(_ trigger: ObjectTrigger, in view: UIView, at point: CGPoint) {
        switch trigger {
        case .tap:
            open()
        case .longPress:
            guard let menu = menu() else { return }
            TapMenuPresenter.shared.present(menu, in: view, at: point, lifecycle: lifecycle)
        }
    }
}
