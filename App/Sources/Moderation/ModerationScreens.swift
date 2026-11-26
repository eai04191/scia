import os
import SciaCore
import UIKit

/// ミュートしたユーザー、ブロックしたユーザー、ブロックしたドメインの画面を作り、開いている人のリストに関係の変化を届ける。セッションが1つ持つ。
/// 決まりはdocs/moderation-lists.mdにある。
@MainActor
final class ModerationScreens {
    let domainBlocks: DomainBlocksModel
    /// 開いているミュートとブロックの人のリスト。画面を閉じると、コントローラーが捨てられて外れる。
    private let accountLists = NSHashTable<AccountListController>.weakObjects()
    private let logger = SciaLog.logger(category: "moderation")

    /// 開いているプロフィール。ドメインのブロックで外れたフォローを反映する。
    struct OpenProfiles {
        /// 開いているプロフィールのうち、そのドメインの人のアカウントのID。
        let accountIDs: @MainActor (String) -> [String]
        /// 再読み込みした関係を入れ、フォロワー数のためにアカウントも再読み込みする。
        let apply: @MainActor (Relationship) -> Void
    }

    private let relationships: RelationshipCache
    private let accounts: AccountCache
    private let openProfiles: OpenProfiles
    private let tasks: TaskScope

    init(client: MastodonClient, tasks: TaskScope, relationships: RelationshipCache, accounts: AccountCache, openProfiles: OpenProfiles) {
        self.relationships = relationships
        self.accounts = accounts
        self.openProfiles = openProfiles
        self.tasks = tasks
        domainBlocks = DomainBlocksModel(api: DomainBlocksModel.API(client: client), tasks: tasks)
        domainBlocks.onChange = { [weak self] domain in
            self?.forgetRelations(onDomain: domain)
        }
    }

    /// ミュートかブロックの人のリストを覚え、関係が変わったら行を消せるようにする。
    func register(_ controller: AccountListController) {
        accountLists.add(controller)
    }

    /// 関係が変わったことを、開いている人のリストに届ける。
    func apply(_ relationship: Relationship) {
        for list in accountLists.allObjects {
            list.apply(relationship)
        }
    }

    /// ユーザーのメニューからドメインのブロックを変えたら、そのドメインの人の関係を忘れ、読んであるドメインのリストを再読み込みする。まだ読んでいなければ、開いたときに読む。
    /// 変えた相手の関係は忘れるので、再読み込みした関係はこのあとに入れる。
    func domainBlocksDidChange(_ domain: String) {
        forgetRelations(onDomain: domain)
        domainBlocks.didChangeOutside()
    }

    /// キャッシュした関係のうち、そのドメインの人と見分けられない人の分を忘れる。開いているそのドメインの人のプロフィールには、再読み込みした関係を入れる。
    /// Mastodonはドメインのブロックでお互いのフォローを外すので、開いたままのプロフィールのフォローのボタンが前のままにならないようにする。
    private func forgetRelations(onDomain domain: String) {
        relationships.forgetRelations(onDomain: domain) { [accounts] id in accounts.account(id)?.acct }
        let ids = openProfiles.accountIDs(domain)
        guard !ids.isEmpty else { return }
        relationships.reload(ids, purpose: .display)
        tasks.run(.display) { [relationships, openProfiles, logger] in
            for id in ids {
                do {
                    guard let relationship = try await relationships.relationship(id) else { continue }
                    openProfiles.apply(relationship)
                } catch {
                    logger.error("open profile relationship reload failed: \(SciaLog.describe(error), privacy: .public)")
                }
            }
        }
    }

    /// ドメインを入れてブロックするアラートを出す。誤って選択して、そのドメインのフォロワーを外さないよう、ユーザーのメニューと同じ説明を添え、赤いボタンで送る。
    /// ブロックできなければ、理由を出してから、入れたドメインを残したまま入力に戻す。
    /// - Parameter text: アラートを出し直すときに残す、前に入れた文字。
    func presentBlockDomain(on presenter: UIViewController, text: String = "") {
        let alert = UIAlertController(title: ModerationTexts.blockDomain, message: ModerationTexts.blockDomainMessage, preferredStyle: .alert)
        let action = UIAlertAction(title: ModerationTexts.block, style: .destructive) { [weak self, weak alert, weak presenter] _ in
            let entered = alert?.textFields?.first?.text ?? ""
            self?.domainBlocks.block(entered) { [weak self, weak presenter] failure in
                guard let failure, let self, let presenter else { return }
                logger.error("domain block failed")
                presenter.presentOnFrontmost(UIAlertController.failure(title: ModerationTexts.blockFailed, reason: failure) { [weak self, weak presenter] in
                    guard let presenter else { return }
                    self?.presentBlockDomain(on: presenter, text: entered)
                })
            }
        }
        alert.addTextField { [weak action] field in
            field.text = text
            field.placeholder = ModerationTexts.domainPlaceholder
            field.clearButtonMode = .whileEditing
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.smartInsertDeleteType = .offOnMac
            field.addAction(UIAction { [weak action, weak field] _ in
                action?.isEnabled = !DomainInput.normalize(field?.text ?? "").isEmpty
            }, for: .editingChanged)
        }
        action.isEnabled = !DomainInput.normalize(text).isEmpty
        alert.addAction(UIAlertAction(title: SettingsTexts.cancel, style: .cancel))
        alert.addAction(action)
        presenter.presentOnFrontmost(alert)
    }
}

extension UserRelationChange {
    /// 人のリストの行から解除するボタンの記号。ユーザーのメニューの同じ操作に揃える。
    var symbolName: String {
        switch self {
        case .unmute: "speaker.wave.2"
        case .unblock: "hand.raised.slash"
        default: "person.badge.minus"
        }
    }
}
