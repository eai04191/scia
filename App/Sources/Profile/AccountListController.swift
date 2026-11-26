import Foundation
import os
import SciaCore

/// 人のリスト（お気に入りした人、ブーストした人、フォロワー、フォロー、リストのメンバー）の読み込みを、TimelineViewControllerの表示へつなぐ。
/// 画面はプロフィールやスレッドと同じくpushで開く。決まりはdocs/account-list.mdにある。リストのメンバーでは、外したり足したりもできる（docs/lists.mdの「メンバー」）。
/// ミュートしたユーザーとブロックしたユーザーでは、行から解除でき、解除したら行を消す（docs/moderation-lists.md）。
@MainActor
final class AccountListController {
    /// 1回に読む件数。APIの上限は80件。
    private static let pageSize = 40

    private weak var viewController: TimelineViewController?
    private let store: AccountListStore
    private let logger = SciaLog.logger(category: "accountList")
    /// この画面が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときと、画面を閉じてこのコントローラーが捨てられたときに閉じる。
    private let tasks: TaskScope
    private let client: MastodonClient
    private let kind: AccountListKind
    /// ミュートとブロックのリストで、行から解除するときに呼ぶ。関係の変更はセッションが送り、送れたら`apply(_:)`で行を消す。
    var onChangeRelation: ((UserRelationChange, Account) -> Void)?
    /// リストのメンバーを並べているなら、そのリスト。
    private let listID: String?
    /// リストのメンバーを外したり足したりできなかったときに呼ぶ。伝え方はセッションが決める。
    var onMemberFailure: ((_ title: String, _ error: any Error) -> Void)?
    /// 人のリストに並んでいる人。リストのメンバーの画面で、足す人を探す画面に、もう入っているかを出すのに使う。
    var accountIDs: Set<String> { Set(store.accounts.map(\.id)) }
    /// 人のリストを読めたかが変わったときに呼ぶ。リストのメンバーの画面では、読めるまで足す人を探す画面を開かせない。
    /// 読む前に開くと、もう入っている人を入っていないものとして出し、選択すると足し直してしまうため。
    var onLoadedChange: ((Bool) -> Void)?

    /// - Parameter emojiReactionStyle: リアクションした人を読むときの、サーバーのAPIの形。ほかのリストでは呼ばれても使わない。
    static func make(
        kind: AccountListKind, client: MastodonClient, settings: AppSettings, tasks: TaskScope,
        emojiReactionStyle: @escaping @MainActor @Sendable () async throws -> EmojiReactionStyle = { .fedibird }
    ) -> (AccountListController, TimelineViewController) {
        // 画面を作る時点ではコントローラーがまだないため、作ったあとに入れる。
        weak var owner: AccountListController?
        let viewController = TimelineViewController(texts: .accountList(kind), settings: settings) { await owner?.refresh() }
        let controller = AccountListController(kind: kind, client: client, viewController: viewController, tasks: tasks, emojiReactionStyle: emojiReactionStyle)
        viewController.lifetimeOwner = controller
        owner = controller
        return (controller, viewController)
    }

    private init(
        kind: AccountListKind, client: MastodonClient, viewController: TimelineViewController, tasks: TaskScope,
        emojiReactionStyle: @escaping @MainActor @Sendable () async throws -> EmojiReactionStyle
    ) {
        self.tasks = tasks
        self.client = client
        self.kind = kind
        if case .listMembers(let listID) = kind {
            self.listID = listID
        } else {
            listID = nil
        }
        // リストのメンバーは、足す人を探す画面でもう入っているかを出せるよう、全員を一度に読む（`limit=0`）。
        // メンバーはフォローしている人に限られ、ページに分けずに読める数で収まる。
        let pageSize = listID == nil ? Self.pageSize : 0
        store = AccountListStore(kind: kind) { maxID in
            // 形を読むのは、リアクションした人のリストだけ。ほかのリストを、サーバーの機能の読み込みで待たせない。
            guard case .emojiReactionedBy = kind else { return try await client.accounts(in: kind, maxID: maxID, limit: pageSize) }
            return try await client.accounts(in: kind, maxID: maxID, limit: pageSize, emojiReactionStyle: emojiReactionStyle())
        }
        self.viewController = viewController
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(purpose: .display) }
        viewController.onRetry = { [weak self] in self?.retry() }
        if listID != nil {
            viewController.onRemoveAccount = { [weak self] account in self?.removeMember(account) }
        } else if let change = kind.removalChange, let title = kind.removalTitle {
            viewController.accountRemoval = (title, change.symbolName)
            viewController.onRemoveAccount = { [weak self] account in self?.onChangeRelation?(change, account) }
        }
    }

    /// 関係が変わって、もうこのリストに入らない人の行を消す。使う人の操作（スワイプか、長押しのメニュー）で消えるので、標準の削除の動きで閉じる。
    /// まだ行がなくても、読んでいる途中の応答に入っていれば読み終えてから除くよう、ストアには伝える。
    func apply(_ relationship: Relationship) {
        guard kind.contains(relationship) == false else { return }
        let isShown = store.accounts.contains { $0.id == relationship.id }
        store.remove(accountID: relationship.id)
        guard isShown else { return }
        showMemberChange(animatesRemoval: true)
        logger.info("accountList removed by relation change")
    }

    /// リストから外す。サーバーが受け付けたら、使う人の操作で行が消えるので、標準の削除の動きで行を閉じる。外せなければ行を残す。
    private func removeMember(_ account: Account) {
        changeMember(account, adds: false) { _ in }
    }

    /// リストに足して人のリストの先頭に出すか、外して人のリストから除く。足す人を探す画面からも使う。
    /// 画面の持ち主の子で始めるので、ログアウトやアカウントの切り替えで止まる。できなければ`onMemberFailure`で知らせる。
    /// - Parameter completion: サーバーが受け付けたかを渡す。
    func changeMember(_ account: Account, adds: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard let listID else { return }
        let client = client
        run(.action) { controller in
            do {
                if adds {
                    try await client.addAccounts([account.id], toList: listID)
                    controller.store.prepend(account)
                    controller.showMemberChange()
                } else {
                    try await client.removeAccounts([account.id], fromList: listID)
                    controller.store.remove(accountID: account.id)
                    controller.showMemberChange(animatesRemoval: true)
                }
                controller.logger.info("accountList member \(adds ? "added" : "removed", privacy: .public) list=\(listID, privacy: .public)")
                completion(true)
            } catch {
                controller.handle(error, during: adds ? "addMember" : "removeMember") { _ in }
                controller.onMemberFailure?((adds ? ListMembershipModel.Operation.add : .remove).failureTitle, error)
                completion(false)
            }
        }
    }

    /// - Parameter purpose: 使う人が開いたり再試行を選択したりしたときは`.action`。電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    @discardableResult
    func start(purpose: RequestPurpose) -> Task<Void, Never>? {
        viewController?.setContentState(.loading)
        onLoadedChange?(false)
        return run(purpose) { controller in
            do {
                guard let accounts = try await controller.store.loadInitial() else { return }
                controller.showEntries()
                controller.viewController?.setContentState(.loaded)
                controller.viewController?.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.onLoadedChange?(true)
                controller.logger.info("accountList loadInitial done count=\(accounts.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadInitial") { controller.viewController?.setContentState(.failed($0)) }
            }
        }
    }

    /// 人のリストでpull to refreshしたときに、最初のページから再読み込みして置き換える。人のリストは新しい人が上に来るとは限らず、上に足せないため。
    /// 読めなかったら、前の人のリストのまま残す。最初の読み込みに失敗したままなら、それをやり直す。
    private func refresh() async {
        logger.info("accountList refresh")
        if case .failed = viewController?.contentState {
            await start(purpose: .action)?.value
            return
        }
        do {
            guard let accounts = try await store.loadInitial() else { return }
            showEntries()
            viewController?.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("accountList refresh done count=\(accounts.count, privacy: .public)")
        } catch {
            handle(error, during: "refresh") { _ in }
        }
    }

    private func retry() {
        if store.accounts.isEmpty {
            start(purpose: .action)
        } else {
            loadOlder(purpose: .action)
        }
    }

    private func loadOlder(purpose: RequestPurpose) {
        guard !store.isLoading, !store.reachedEnd, !store.accounts.isEmpty else { return }
        viewController?.setFooterState(.loading)
        run(purpose) { controller in
            do {
                guard let added = try await controller.store.loadOlder() else { return }
                controller.showEntries()
                controller.viewController?.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("accountList loadOlder done added=\(added.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController?.setFooterState(.failed($0)) }
            }
        }
    }

    @discardableResult
    private func run(_ purpose: RequestPurpose, _ operation: @escaping @MainActor (AccountListController) async -> Void) -> Task<Void, Never>? {
        tasks.run(purpose) { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    /// 人を足したり外したりしたあとに再描画する。末尾の「メンバーはいません」などは、行の有無で出し分けるので、再描画させる。
    private func showMemberChange(animatesRemoval: Bool = false) {
        showEntries(animatesRemoval: animatesRemoval)
        viewController?.setContentState(.loaded)
        viewController?.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
    }

    private func showEntries(animatesRemoval: Bool = false) {
        viewController?.setEntries(store.accounts.map(TimelineEntry.account), animatesRemoval: animatesRemoval)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("accountList \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        show(ErrorPresentation(error))
    }
}
