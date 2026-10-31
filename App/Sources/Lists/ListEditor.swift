import os
import SciaCore
import UIKit

/// `ListEditor`が、セッションに頼むこと。
@MainActor
protocol ListEditorHost: AnyObject {
    /// アラートやシートを出す、いちばん手前の画面。
    var listPresenter: UIViewController { get }
    /// 手元で覚えているリスト。読んでいなければnil。
    func knownList(_ id: String) -> MastodonList?
    /// 作ったリストを、並びに有効にして足す。
    func listDidCreate(_ list: MastodonList)
    /// 変えたリストを、並びとタブの名前に入れる。
    func listDidUpdate(_ list: MastodonList)
    /// 消したリストを、並びから外して購読を止める。
    func listDidDelete(_ id: String)
    /// 失敗の理由。401ならトークンが無効かを確かめてから文言を選ぶ。
    func listFailureReason(for error: any Error) async -> ErrorPresentation
    /// 押し直せば済む失敗を、「操作の状況」に残してチップで知らせる。押すと理由が出る。
    func reportListFailure(title: String, reason: ErrorPresentation)
}

/// リストを作る、名前と設定を変える、消す。決まりはdocs/lists.mdにある。
/// 名前を入れるのはアラートで、作ったり名前を変えたりできなければ、理由を出してから、入れた名前を残したまま入力に戻す。
@MainActor
final class ListEditor {
    private let client: MastodonClient
    private let tasks: TaskScope
    private weak var host: (any ListEditorHost)?
    private let logger = SciaLog.logger(category: "listEditor")
    /// リストごとの、送っている途中の名前と設定の変更。
    private var updating: [String: Task<Void, Never>] = [:]

    init(client: MastodonClient, tasks: TaskScope, host: any ListEditorHost) {
        self.client = client
        self.tasks = tasks
        self.host = host
    }

    // MARK: - 作る

    /// 名前を入れるアラートを出して、リストを作る。
    /// - Parameter create: 作る処理。「リストに追加」のシートは、作ったリストに人を足すので、自分の処理を渡す。
    /// - Parameter onCreate: 作れたら呼ぶ。
    func presentCreate(text: String = "", create: (@MainActor (String) async throws -> MastodonList)? = nil, onCreate: @escaping @MainActor (MastodonList) -> Void = { _ in }) {
        let client = client
        let create = create ?? { title in try await client.createList(title: title) }
        presentNameInput(title: "リストを作成", text: text, actionTitle: "作成", failureTitle: "リストを作成できませんでした") { [weak self] title in
            let list = try await create(title)
            self?.logger.info("list created id=\(list.id, privacy: .public)")
            self?.host?.listDidCreate(list)
            onCreate(list)
        }
    }

    // MARK: - 変える

    /// 名前を入れるアラートを出して、リストの名前を変える。
    func presentRename(listID: String, currentTitle: String, text: String? = nil) {
        let client = client
        presentNameInput(title: "リストの名前", text: text ?? currentTitle, actionTitle: "保存", failureTitle: "リストの名前を変えられませんでした") { [weak self] title in
            try await self?.enqueue(listID) { [weak self] in
                guard title != self?.host?.knownList(listID)?.title ?? currentTitle else { return }
                let list = try await client.updateList(listID, title: title)
                self?.logger.info("list renamed id=\(listID, privacy: .public)")
                self?.host?.listDidUpdate(list)
            }
        }
    }

    /// 返信の表示かホームに出さないを変える。押し直せば済むので、失敗はチップで知らせる。
    func update(_ list: MastodonList, repliesPolicy: ListRepliesPolicy? = nil, exclusive: Bool? = nil) {
        let client = client
        let failureTitle = repliesPolicy != nil ? "返信の表示を変えられませんでした" : "ホームに出さないを切り替えられませんでした"
        tasks.run(.action) { [weak self] in
            do {
                try await self?.enqueue(list.id) { [weak self] in
                    // サーバーは名前を毎回求めるので、前の変更で名前が変わっていれば、その名前で送る。メニューを開いたときの名前で送ると、名前を戻してしまうため。
                    let title = self?.host?.knownList(list.id)?.title ?? list.title
                    let updated = try await client.updateList(list.id, title: title, repliesPolicy: repliesPolicy, exclusive: exclusive)
                    self?.logger.info("list settings updated id=\(list.id, privacy: .public)")
                    self?.host?.listDidUpdate(updated)
                }
            } catch {
                await self?.reportFailure(error, title: failureTitle, during: "update")
            }
        }
    }

    /// 名前と設定の変更を、リストごとに順に送る。前の変更の応答を待ってから送るので、応答が前後して古い設定を覚えることもない。
    private func enqueue(_ listID: String, _ send: @escaping @MainActor () async throws -> Void) async throws {
        let outcome = UpdateOutcome()
        let previous = updating[listID]
        let task = tasks.run(.action) {
            await previous?.value
            do {
                try await send()
            } catch {
                outcome.error = error
            }
        }
        updating[listID] = task
        await task?.value
        if updating[listID] == task {
            updating[listID] = nil
        }
        if let error = outcome.error {
            throw error
        }
    }

    // MARK: - 消す

    /// 確かめてから消す。消すとメンバーの設定も戻せないため。
    func confirmDelete(listID: String, title: String) {
        let alert = UIAlertController(Confirmation.deletingList(title: title), preferredStyle: .alert) { [weak self] _ in
            self?.delete(listID: listID)
        }
        host?.listPresenter.present(alert, animated: true)
    }

    private func delete(listID: String) {
        let client = client
        tasks.run(.action) { [weak self] in
            do {
                try await client.deleteList(listID)
                guard let self else { return }
                logger.info("list deleted id=\(listID, privacy: .public)")
                host?.listDidDelete(listID)
            } catch {
                await self?.reportFailure(error, title: "リストを削除できませんでした", during: "delete")
            }
        }
    }

    // MARK: - 一覧の右上のメニュー

    /// リストのタイムラインの右上に置くボタン。リストの設定は開いている間にも変わるので、メニューを開くたびに覚えているリストを見て中身を決める。
    /// - Parameter openMembers: 「メンバー」で、メンバーの画面を開く。
    func barItem(listID: String, fallbackTitle: String, openMembers: @escaping @MainActor (_ title: String) -> Void) -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            completion(menuElements(listID: listID, fallbackTitle: fallbackTitle, openMembers: openMembers))
        }])
        // 右上に入り切らず「さらに表示」にまとめられたときも、何のボタンか分かるよう名前を付ける。
        return UIBarButtonItem(title: "リスト", image: UIImage(systemName: "ellipsis"), menu: menu)
    }

    private func menuElements(listID: String, fallbackTitle: String, openMembers: @escaping @MainActor (_ title: String) -> Void) -> [UIMenuElement] {
        let list = host?.knownList(listID)
        let title = list?.title ?? fallbackTitle
        var main: [UIMenuElement] = [
            UIAction(title: "名前を変える", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.presentRename(listID: listID, currentTitle: title)
            },
            UIAction(title: "メンバー", image: UIImage(systemName: "person.2")) { _ in
                openMembers(title)
            },
        ]
        // 設定はリストを読めてから出す。読む前の値で選ばせると、送る値が今の設定とずれるため。
        if let list {
            main.append(UIMenu(title: "返信の表示", subtitle: list.repliesPolicy?.title, image: UIImage(systemName: "arrowshape.turn.up.left"), children: ListRepliesPolicy.allCases.map { policy in
                UIAction(title: policy.title, state: list.repliesPolicy == policy ? .on : .off) { [weak self] _ in
                    guard list.repliesPolicy != policy else { return }
                    self?.update(list, repliesPolicy: policy)
                }
            }))
            // 返さないサーバー（Mastodon 4.2より前）には、この設定がない。
            if let exclusive = list.exclusive {
                main.append(UIAction(title: "ホームに出さない", image: UIImage(systemName: "house.slash"), state: exclusive ? .on : .off) { [weak self] _ in
                    self?.update(list, exclusive: !exclusive)
                })
            }
        }
        let delete = UIAction(title: "削除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(listID: listID, title: title)
        }
        return [UIMenu(options: .displayInline, children: main), UIMenu(options: .displayInline, children: [delete])]
    }

    // MARK: - 名前の入力

    /// 名前を入れるアラート。空では送れない。送れなければ理由のアラートを出し、閉じると入れた名前を残したまま、このアラートに戻す。
    private func presentNameInput(title: String, text: String, actionTitle: String, failureTitle: String, submit: @escaping @MainActor (String) async throws -> Void) {
        guard let presenter = host?.listPresenter else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let action = UIAlertAction(title: actionTitle, style: .default) { [weak self, weak alert] _ in
            let entered = alert?.textFields?.first?.text ?? ""
            let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.tasks.run(.action) { [weak self] in
                do {
                    try await submit(name)
                } catch {
                    guard let self, let host, !(error is CancellationError) else { return }
                    logger.error("list name submit failed: \(SciaLog.describe(error), privacy: .public)")
                    let reason = await host.listFailureReason(for: error)
                    let failure = UIAlertController(title: failureTitle, message: reason.text, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                        self?.presentNameInput(title: title, text: entered, actionTitle: actionTitle, failureTitle: failureTitle, submit: submit)
                    })
                    host.listPresenter.present(failure, animated: true)
                }
            }
        }
        alert.addTextField { [weak action] field in
            field.text = text
            field.placeholder = "リストの名前"
            field.clearButtonMode = .whileEditing
            field.addAction(UIAction { [weak action, weak field] _ in
                action?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, for: .editingChanged)
        }
        action.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(action)
        alert.preferredAction = action
        presenter.present(alert, animated: true)
    }

    private func reportFailure(_ error: any Error, title: String, during operation: String) async {
        guard !(error is CancellationError), let host else { return }
        logger.error("list \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        host.reportListFailure(title: title, reason: await host.listFailureReason(for: error))
    }
}

/// 順に送った変更の失敗を、送るのを待っていた側へ渡す入れ物。
@MainActor
private final class UpdateOutcome {
    var error: (any Error)?
}
