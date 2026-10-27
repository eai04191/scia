import SciaCore
import UIKit

/// 一覧の行と、行の中の部品のタップと長押し。決まりはdocs/object-actions.mdにある。
extension TimelineViewController {
    func installRowObjectActions() {
        touchRecorder.cancelsTouchesInView = false
        touchRecorder.delaysTouchesEnded = false
        collectionView.addGestureRecognizer(touchRecorder)
        rowLongPress = ObjectLongPress(on: collectionView, accepts: { [weak self] location in
            guard let self, let indexPath = collectionView.indexPathForItem(at: location) else { return false }
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
        case .gap, .unreadable:
            return nil
        }
    }

    /// 投稿と通知の行。主な操作は、行のスレッドを開く。開けない行（スレッドの中心の投稿、投稿のない通知）では行えない。
    private func rowStatusTarget(_ entity: ObjectEntity<StatusMenuItem>, entry: TimelineEntry, id: ItemID, opening status: Status?) -> ObjectTarget<StatusMenuItem> {
        ObjectTarget(
            entity: entity,
            settings: settings,
            primaryIsAvailable: status.map(canOpenThread(of:)) ?? false,
            primary: { [weak self] _ in
                guard let self, let status, canOpenThread(of: status) else { return }
                recordOpenThread()
                onOpenThread?(status, rowFrame(of: id))
            },
            buildMenu: { [weak self] groups in self?.contextMenu(for: entry, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// ユーザー。人の一覧の行と、行の中のアイコンや「〜がブースト」の行。長押しの既定は、その人のユーザーのメニュー。
    func userTarget(for account: Account, id: ItemID) -> ObjectTarget<UserMenuItem> {
        ObjectTarget(
            entity: .user,
            settings: settings,
            primaryIsAvailable: onOpenProfile != nil,
            primary: { [weak self] _ in self?.onOpenProfile?(account) },
            buildMenu: { [weak self] groups in self?.userMenu(for: .account(account), id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// 引用の囲み。対象は引用元の投稿で、メニューは引用元の投稿の投稿のメニュー。
    /// - Parameter openThread: 主な操作（スレッドを開く）で行う、今のタップの処理。押した囲みを渡す。
    func statusTarget(for status: Status, id: ItemID, openThread: @escaping (UIView) -> Void) -> ObjectTarget<StatusMenuItem> {
        let entry = TimelineEntry.status(status)
        return ObjectTarget(
            entity: .status,
            settings: settings,
            primary: openThread,
            buildMenu: { [weak self] groups in self?.contextMenu(for: entry, id: id, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// リンクカードとXの投稿の囲み。対象はリンクで、メニューはリンクのメニュー。
    /// - Parameter open: 主な操作（ブラウザで開く）で行う、今のタップの処理。
    func linkTarget(for url: URL, id: ItemID, open: @escaping () -> Void) -> ObjectTarget<LinkMenuItem> {
        ObjectTarget(
            entity: .link,
            settings: settings,
            primary: { _ in open() },
            buildMenu: { [weak self] groups in self?.linkMenu(for: url, id: id, groups: groups) },
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
