import SciaCore
import UIKit

/// 選び始める前のナビゲーションバーの中身。選び終えたら戻す。
struct PostSelectionNavigationItems {
    let title: String?
    let subtitle: String?
    let titleView: UIView?
    let leftBarButtonItems: [UIBarButtonItem]?
    let hidesBackButton: Bool
}

/// まとめて行う操作のために、一覧で投稿を順番を付けて選ぶ。決まりはdocs/batch-actions.mdにある。
extension TimelineViewController {
    var isSelectingPosts: Bool { postSelection != nil }

    /// `id`の行を選べるか。投稿の行と投稿の付いた通知の行で、まとめて行う操作を受ける一覧でだけ選べる。
    func canSelectPost(_ id: ItemID) -> Bool {
        guard onBatchReblog != nil, onBatchShare != nil, let entry = entry(for: id) else { return false }
        switch entry {
        case .status, .pinned: return true
        case .notification(let notification): return notification.status != nil
        case .gap, .unreadable, .account, .notificationRequest, .search: return false
        }
    }

    /// `id`の行を1番目に選んで、選び始める。選んでいる途中なら、その行を選ぶだけにする。
    func beginPostSelection(with id: ItemID) {
        guard canSelectPost(id) else { return }
        guard postSelection == nil else {
            if postSelection?.contains(id) == false { togglePostSelection(id) }
            return
        }
        endTextSelection()
        UserAction.beginPostSelection(screen: screenName).record()
        postSelection = OrderedSelection([id])
        navigationItemBeforePostSelection = PostSelectionNavigationItems(
            title: navigationItem.title,
            subtitle: navigationItem.subtitle,
            titleView: navigationItem.titleView,
            leftBarButtonItems: navigationItem.leftBarButtonItems,
            hidesBackButton: navigationItem.hidesBackButton
        )
        navigationItem.titleView = nil
        navigationItem.subtitle = nil
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItems = [UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.endPostSelection() })]
        navigationItem.rightBarButtonItems = []
        toolbarItems = makePostSelectionToolbarItems()
        // タブバーの上にはツールバーを重ねられないため、写真の選択と同じく、選んでいる間はタブバーを隠してツールバーを出す。
        tabBarController?.setTabBarHidden(true, animated: true)
        navigationController?.setToolbarHidden(false, animated: true)
        onPostSelectionChange?(true)
        updatePostSelectionDisplay()
        updateObscuredBottomInsetForPostSelection()
    }

    /// 選ぶのをやめ、ナビゲーションバーとツールバーを戻す。溜めていた新着を入れる。
    func endPostSelection() {
        guard postSelection != nil else { return }
        postSelection = nil
        if let saved = navigationItemBeforePostSelection {
            navigationItem.title = saved.title
            navigationItem.subtitle = saved.subtitle
            navigationItem.titleView = saved.titleView
            navigationItem.leftBarButtonItems = saved.leftBarButtonItems
            navigationItem.hidesBackButton = saved.hidesBackButton
        }
        navigationItemBeforePostSelection = nil
        applyBarItems()
        navigationController?.setToolbarHidden(true, animated: true)
        tabBarController?.setTabBarHidden(false, animated: true)
        toolbarItems = nil
        onPostSelectionChange?(false)
        refreshSelectionMarks()
        updateObscuredBottomInsetForPostSelection()
        reportInteractionSettled()
    }

    /// `id`の行を選んでいなければ最後に選び、選んでいれば外して後ろの番号を詰める。
    func togglePostSelection(_ id: ItemID) {
        guard postSelection != nil, canSelectPost(id) else { return }
        postSelection?.toggle(id)
        updatePostSelectionDisplay()
    }

    /// 一覧から消えた行を選択から外す。並びを変えるたびに呼ぶ。
    func prunePostSelection() {
        guard postSelection?.keep(where: canSelectPost) == true else { return }
        updatePostSelectionDisplay()
    }

    /// 行に出す丸。選べない行と、選んでいないときはnil。
    func selectionMark(for id: ItemID) -> TimelineCell.SelectionMark? {
        guard let postSelection, canSelectPost(id) else { return nil }
        return postSelection.number(of: id).map(TimelineCell.SelectionMark.selected) ?? .unselected
    }

    /// 選んだ順の投稿。通知なら対象の投稿。
    var selectedStatuses: [Status] {
        (postSelection?.ids ?? []).compactMap(status(for:))
    }

    private func updatePostSelectionDisplay() {
        guard let postSelection else { return }
        navigationItem.title = postSelection.isEmpty ? "投稿を選択" : "\(postSelection.count)件を選択"
        for item in toolbarItems ?? [] where item.tag == Self.postSelectionActionTag {
            item.isEnabled = !postSelection.isEmpty
        }
        refreshSelectionMarks()
    }

    private func refreshSelectionMarks() {
        for cell in collectionView.visibleCells {
            guard let cell = cell as? TimelineCell, let id = cell.itemID else { continue }
            cell.setSelectionMark(selectionMark(for: id))
        }
    }

    private func updateObscuredBottomInsetForPostSelection() {
        // 投稿欄のカプセルの分の余白を、選んでいる間は外し、選び終えたら戻す。
        updateObscuredBottomInset()
    }

    /// ツールバーで押せるかを選んだ数で切り替えるボタンの目印。
    private static var postSelectionActionTag: Int { 0x5E1EC7 }

    private func makePostSelectionToolbarItems() -> [UIBarButtonItem] {
        let reblog = UIBarButtonItem(title: "ブースト", image: UIImage(systemName: "arrow.2.squarepath"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.batchReblogMenuElements() ?? [])
            },
        ]))
        reblog.tag = Self.postSelectionActionTag
        let share = UIBarButtonItem(primaryAction: UIAction(title: "共有", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let statuses = selectedStatuses
            guard !statuses.isEmpty else { return }
            UserAction.batchShare.record()
            endPostSelection()
            onBatchShare?(statuses)
        })
        share.tag = Self.postSelectionActionTag
        return [reblog, .flexibleSpace(), share]
    }

    /// まとめてブーストを確かめるメニュー。ブースト済みの投稿の前のブーストに付いた反応が消えるため、ボタン1つで始めずに、件数を見せてから始める。
    private func batchReblogMenuElements() -> [UIMenuElement] {
        let statuses = selectedStatuses
        guard let myAccountID, !statuses.isEmpty else { return [] }
        let plan = BatchReblogPlan(statuses: statuses, myAccountID: myAccountID)
        var notes: [String] = []
        if plan.reblogAgainCount > 0 { notes.append("ブースト済みの\(plan.reblogAgainCount)件は付け直します") }
        if plan.skippedCount > 0 { notes.append("ブーストできない\(plan.skippedCount)件は飛ばします") }
        let start = UIAction(
            title: "選んだ順にブースト（\(plan.steps.count)件）",
            subtitle: notes.isEmpty ? nil : notes.joined(separator: "。"),
            image: UIImage(systemName: "arrow.2.squarepath"),
            attributes: plan.steps.isEmpty ? .disabled : []
        ) { [weak self] _ in
            guard let self else { return }
            UserAction.batchReblog.record()
            endPostSelection()
            onBatchReblog?(statuses)
        }
        return [start]
    }
}
