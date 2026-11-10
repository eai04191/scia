import SciaCore
import UIKit

/// タイムラインの行と、行の中の部品のタップと長押し。決まりはdocs/object-actions.mdにある。
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

    /// 行の対象。投稿、通知、人のリストの行で、ほかの行（ギャップ、読めなかった行）ではnil。
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
        var target = ObjectTarget(
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
        if canShowActionBar(in: entry) {
            target.openActionBar = { [weak self] _ in self?.toggleActionBar(for: id) }
        }
        return target
    }

    /// アクションバーのボタンを押したときに、その項目を行う。投稿のメニューの項目は、タップに割り当てた1項目と同じ組み方で行い、「メニュー」は行の投稿のメニューをボタンから出す。
    /// 決まりはdocs/post-action-bar.mdの「ボタン」にある。
    func performActionBarItem(_ item: PostActionBarItem, id: ItemID, from button: UIView) {
        guard let entry = entry(for: id) else { return }
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        switch item {
        case .menu:
            guard let menu = contextMenu(for: entry, id: id) else { return }
            TapMenuPresenter.shared.present(menu, in: button, at: point, lifecycle: rowMenuLifecycle)
        case .status(let statusItem):
            rowStatusTarget(.status, entry: entry, id: id, opening: Self.status(of: entry)).perform(statusItem, in: button, at: point)
        }
    }

    /// アクションバーのボタンを長押しして出すメニュー。項目（`PostActionBarItem.longPressItems`）は、投稿のメニューと同じ組み方で組む。
    func actionBarLongPressTarget(for item: PostActionBarItem, id: ItemID) -> (any ObjectActionTarget)? {
        let items = item.longPressItems
        guard !items.isEmpty else { return nil }
        return ActionBarMenuTarget(
            buildMenu: { [weak self] in
                guard let self, let entry = entry(for: id) else { return nil }
                return statusMenu(for: entry, id: id, groups: .items(items))?.menu
            },
            lifecycle: rowMenuLifecycle
        )
    }

    /// ユーザー。人のリストの行と、行の中のアイコンや「〜がブースト」の行。長押しの既定は、その人のユーザーのメニュー。
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
            entity: .quotedStatus,
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

    /// 投稿の絵文字のリアクションのボタン。主な操作は付け外し（今のタップの処理）。決まりはdocs/emoji-reaction.mdの「リアクションのボタンのメニュー」にある。
    func reactionTarget(for status: Status, reaction: EmojiReaction) -> ObjectTarget<ReactionMenuItem, ReactionMenuCommand> {
        ObjectTarget(
            entity: .reaction,
            settings: settings,
            primaryIsAvailable: onToggleEmojiReaction != nil,
            primary: { [weak self] _ in self?.onToggleEmojiReaction?(status, reaction.emoji) },
            buildMenu: { [weak self] groups in self?.builtReactionMenu(for: status, reaction: reaction, groups: groups) },
            lifecycle: rowMenuLifecycle,
            notify: { [weak self] in self?.showNotice($0) }
        )
    }

    /// リアクションのボタンを長押ししたときに出すメニュー。出す項目がなければnil。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。
    func builtReactionMenu(for status: Status, reaction: EmojiReaction, groups: MenuLayout<ReactionMenuItem>.Groups? = nil) -> BuiltMenu<ReactionMenuCommand>? {
        let tree = ReactionMenuTree(reaction: reaction)
        let subject = OperationStatus.Subject(status.displayed)
        return tree.menu(groups: groups ?? settings.reactionMenuLayout.groups).map { root in
            BuiltMenu(root: root, renderer: MenuRenderer { [weak self] command in
                guard let self else { return }
                switch command {
                case .toggle:
                    onToggleEmojiReaction?(status, reaction.emoji)
                case .openReactedBy:
                    onOpenEmojiReactionedBy?(status, reaction.emoji)
                case .open:
                    // 絵文字は文字の中に描いていて1つずつのビューがないため、投稿のメニューの「カスタム絵文字」と同じく、画像を動かさずに薄くして開く。
                    guard let attachment = reaction.emoji.customEmoji?.attachment else { return }
                    openMedia([attachment], at: 0, subject: subject) { _ in nil }
                case .customize:
                    openMenuSettings(.reactionMenu)
                }
            })
        }
    }

    /// 行の中から出したメニューを開いている間と閉じたあと。コンテキストメニューと同じく、開いている間はタイムラインを動かさず、メニューに出る人のアイコンを読む。
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

    /// 投稿の行のスワイプで出すボタン。投稿のほかの行と、出せるボタンがない行ではnil。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
    /// ボタンを出せるかと今の名前は、アクションバーのボタンと同じく、組むだけで通信しない投稿のメニューの木で決める。押したら、タップに割り当てた1項目と同じ組み方で行う。
    func postSwipe(at indexPath: IndexPath, side: PostSwipeSide) -> UISwipeActionsConfiguration? {
        guard !isSelectingPosts, let id = itemID(at: indexPath), let entry = entry(for: id) else { return nil }
        let status: Status
        switch entry {
        case .status(let rowStatus), .pinned(let rowStatus): status = rowStatus
        default: return nil
        }
        let items = switch side {
        case .leading: settings.postLeadingSwipeLayout.swipeItems
        case .trailing: settings.postTrailingSwipeLayout.swipeItems
        }
        guard !items.isEmpty, let rowHeight = collectionView.cellForItem(at: indexPath)?.bounds.height else { return nil }
        let tree = offlineStatusMenuTree(for: status, id: id, canSelectText: selectableBody(for: id, statusID: status.displayed.id) != nil)
        let actions = items.compactMap { item -> UIContextualAction? in
            guard let button = swipeButton(for: item, entry: entry, id: id, tree: tree) else { return nil }
            let action = UIContextualAction(style: button.isDestructive ? .destructive : .normal, title: PostSwipeLabel.text(for: button.title, rowHeight: rowHeight)) { [weak self] _, sourceView, completion in
                self?.performSwipeItem(item, id: id, from: sourceView)
                // 削除のように行が消える操作も、確かめてからサーバーが受け付けて消すので、行はいったん元の位置に戻す。
                completion(false)
            }
            let image = UIImage(systemName: button.symbolName)
            // 名前を出さない高さの行でも、VoiceOverには省略しない名前を読ませる。
            image?.accessibilityLabel = button.title
            action.image = image
            return action
        }
        guard !actions.isEmpty else { return nil }
        return UISwipeActionsConfiguration(actions: actions)
    }

    /// スワイプのボタンの名前とアイコン。その投稿で出ないか押せなければnil。
    private func swipeButton(for item: PostSwipeItem, entry: TimelineEntry, id: ItemID, tree: StatusMenuTree) -> PostSwipeButton? {
        switch item {
        case .menu:
            guard tree.menu(groups: defaultStatusMenuGroups(for: id, status: Self.status(of: entry)), includesFollowRequest: false).root != nil else { return nil }
            return PostSwipeButton(title: "メニュー", symbolName: item.symbolName)
        case .actionBar:
            guard !settings.appearance.showsActionBar, canShowActionBar(in: entry) else { return nil }
            let title = openActionBarItemID == id ? "アクションバーを閉じる" : item.title
            return PostSwipeButton(title: title, symbolName: item.symbolName)
        case .status(let statusItem):
            let root = tree.menu(groups: .single(statusItem), includesFollowRequest: false).root
            switch MenuItemOutcome(singleItemMenu: root) {
            case .unavailable:
                return nil
            case .perform:
                // 1つの操作なら、メニューに出す今の名前とアイコン（「お気に入りを取り消す」など）にする。
                guard let node = root?.flattenedChildren.first else { return nil }
                return PostSwipeButton(title: node.title, symbolName: node.icon?.symbolName ?? item.symbolName, isDestructive: node.isDestructive)
            case .submenu(let node):
                return PostSwipeButton(title: node.title, symbolName: node.icon?.symbolName ?? item.symbolName)
            case .menu:
                return PostSwipeButton(title: item.title, symbolName: item.symbolName)
            }
        }
    }

    /// スワイプのボタンを押したときに、その操作を行う。メニューを出すものは、押したボタンの位置に出す。
    private func performSwipeItem(_ item: PostSwipeItem, id: ItemID, from button: UIView) {
        guard let entry = entry(for: id) else { return }
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        rowStatusTarget(.status, entry: entry, id: id, opening: Self.status(of: entry)).perform(action: item.action, in: button, at: point)
    }
}

/// 投稿の行のどちらの側のスワイプか。先頭の側は右にスワイプ、末尾の側は左にスワイプで出す（右から左へ書く言語では逆）。
enum PostSwipeSide {
    case leading
    case trailing
}

/// 投稿のスワイプの1つのボタンの見え方。
private struct PostSwipeButton {
    let title: String
    let symbolName: String
    var isDestructive = false
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

    /// 長押しは、タイムラインのコンテキストメニューで出す。
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

/// アクションバーのボタンを長押しして出すメニューだけを持つ対象。タップはボタンが自分で受けるので、ここでは行わない。
@MainActor
private struct ActionBarMenuTarget: ObjectActionTarget {
    let buildMenu: () -> UIMenu?
    let lifecycle: MenuLifecycle

    func menu() -> UIMenu? {
        buildMenu()
    }

    var acceptsTap: Bool { false }

    func performsLongPress() -> Bool {
        false
    }

    func perform(_ trigger: ObjectTrigger, in view: UIView, at point: CGPoint) {}
}
