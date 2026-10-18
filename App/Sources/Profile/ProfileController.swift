import Observation
import os
import SciaCore
import UIKit

/// プロフィール画面。ProfileStoreの状態を、ヘッダーと投稿の一覧へつなぐ。
///
/// 画面はナビゲーションに積まれて閉じられるまで生きるため、画面の方がこのコントローラーを持つ。
/// コントローラーから画面へは弱く持ち、互いに持ち合って残り続けないようにする。
@MainActor
final class ProfileController {
    private(set) weak var viewController: TimelineViewController?
    private let store: ProfileStore
    private let header: ProfileHeaderView
    private let settings: AppSettings
    /// フォローの失敗をどう知らせるか。ログインし直しが要るなどの判断はセッションに任せる。
    private let onError: (any Error, String) -> Void
    /// 読み込みが401で失敗したときに呼ぶ。読み込みの失敗はアラートを出さず画面の中に出すため、`onError`とは分ける。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "profile")
    private var tasks: [Task<Void, Never>] = []
    /// 表示している一覧と、その一覧のタブ。切り替えた一覧が届くまでは、前の一覧を出し続ける。
    private var shownTimeline: TimelineStore
    private var shownTab: ProfileTab

    /// 画面とコントローラーを作る。画面が閉じられると、コントローラーも解放される。
    static func make(
        account: Account,
        client: MastodonClient,
        settings: AppSettings = AppDependencies.settings,
        onError: @escaping (any Error, String) -> Void,
        onUnauthorized: @escaping () -> Void
    ) -> (ProfileController, TimelineViewController) {
        let viewController = TimelineViewController(texts: .profile)
        let controller = ProfileController(
            account: account,
            client: client,
            settings: settings,
            viewController: viewController,
            onError: onError,
            onUnauthorized: onUnauthorized
        )
        viewController.lifetimeOwner = controller
        return (controller, viewController)
    }

    private init(
        account: Account,
        client: MastodonClient,
        settings: AppSettings,
        viewController: TimelineViewController,
        onError: @escaping (any Error, String) -> Void,
        onUnauthorized: @escaping () -> Void
    ) {
        store = ProfileStore(account: account, myAccountID: client.credential.accountID, postsFilter: settings.profilePostsFilter, api: ProfileStore.API(client: client))
        header = ProfileHeaderView(emojiImages: viewController.emojiImages, mediaImages: viewController.mediaImages, avatarImages: viewController.avatarImages)
        shownTimeline = store.timeline
        shownTab = store.tab
        self.settings = settings
        self.onError = onError
        self.onUnauthorized = onUnauthorized
        self.viewController = viewController
        viewController.filterWarnings = FilterWarnings(filtering: store.filtering)
        viewController.headerView = header
        viewController.myAccountID = client.credential.accountID
        viewController.navigationItem.title = "@\(account.acct)"
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder() }
        viewController.onRetry = { [weak self] in self?.retry() }
        header.onToggleFollow = { [weak self] source in self?.confirmToggleFollow(from: source) }
        header.onRetryRelationship = { [weak self] in self?.reloadRelationship() }
        header.onSelectTab = { [weak self] tab in self?.select(tab) }
        header.onChangePostsFilter = { [weak self] filter in self?.changePostsFilter(filter) }
        header.onOpenOriginal = { [weak self] in
            guard let url = self?.store.account.url else { return }
            UIApplication.shared.open(url)
        }
        header.onOpenImage = { [weak self] image in self?.openImage(image) }
        observeHeaderContent()
        // 名前や自己紹介の絵文字が届いたら、ヘッダーを描き直す。投稿の絵文字は一覧が描き直す。
        viewController.emojiImages.addListener(owner: self) { [weak self] urls in
            guard let self, !Set(self.store.account.emojis.map(\.staticUrl)).isDisjoint(with: urls) else { return }
            self.updateHeader()
        }
    }

    /// ヘッダーに出す値が変わったら描き直す。フォローを送っている途中の表示も、ここで切り替わる。
    private func observeHeaderContent() {
        withObservationTracking {
            updateHeader()
            _ = store.pinned
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeHeaderContent()
                self.showEntries()
            }
        }
    }

    func start() {
        loadProfile()
        loadInitial()
    }

    /// 投稿への操作の結果を、固定された投稿と一覧に反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿を、固定された投稿と一覧から除く。
    func removeStatus(_ id: Status.ID) {
        guard store.removeStatus(id) else { return }
        showEntries()
    }

    private func run(_ operation: @escaping @MainActor (ProfileController) async -> Void) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            await operation(self)
        })
    }

    private func updateHeader() {
        let account = store.account
        header.apply(ProfileHeaderView.Content(
            account: account,
            followState: store.followState,
            followedBy: store.relationship?.followedBy ?? false,
            isChangingFollow: store.isChangingFollow,
            isReloadingRelationship: store.isReloadingRelationship,
            tab: store.tab,
            postsFilter: store.postsFilter,
            avatarShape: settings.avatarShape,
            animatesAvatar: settings.animatesAvatars,
            glyphLanguage: settings.glyphLanguageIdentifier(),
            // ローカルのアカウントのacctには@以降が付かない。
            isRemote: account.acct.contains("@")
        ))
        viewController?.headerDidChangeSize()
    }

    /// - Parameter replacing: 一覧を切り替えた。タブを押した場所に残し、その下の中身だけを差し替える。
    private func showEntries(replacing: Bool = false) {
        let pinned = shownTab == .posts ? store.pinned : []
        viewController?.setEntries(pinned.map(TimelineEntry.pinned) + shownTimeline.entries, keepsOffset: replacing)
    }

    /// アイコンかヘッダー画像を、添付ファイルと同じビューアで開く。1枚だけを開き、左右に切り替えない。
    private func openImage(_ image: ProfileImage) {
        guard let attachment = store.account.attachment(of: image) else { return }
        viewController?.openMedia([attachment], at: 0, subject: nil) { [weak header] _ in
            header?.viewerSource(for: image)
        }
    }

    // MARK: - 読み込み

    /// 読めなかったものはアラートにしない。関係はフォローのボタンの場所で知らせ、アカウントと固定された投稿は、開いた時点の内容のままにしてログだけ残す。
    private func loadProfile() {
        run { controller in
            let failures = await controller.store.loadProfile()
            for (part, error) in [("account", failures.account), ("relationship", failures.relationship), ("pinned", failures.pinned)] {
                guard let error else { continue }
                controller.logger.error("profile \(part, privacy: .public) load failed: \(SciaLog.describe(error), privacy: .public)")
                controller.handleUnauthorized(error)
            }
        }
    }

    /// フォローのボタンの場所の再試行。失敗したら、読めなかった表示のまま残す。
    private func reloadRelationship() {
        run { controller in
            do {
                try await controller.store.reloadRelationship()
            } catch {
                controller.logger.error("profile relationship reload failed: \(SciaLog.describe(error), privacy: .public)")
                controller.handleUnauthorized(error)
            }
        }
    }

    private func loadInitial() {
        let timeline = store.timeline
        viewController?.setFooterState(.loading)
        run { controller in
            do {
                guard try await timeline.loadInitial() != nil, timeline === controller.store.timeline else { return }
                controller.shownTimeline = timeline
                controller.shownTab = controller.store.tab
                controller.showEntries(replacing: true)
                controller.viewController?.setFooterState(timeline.reachedEnd ? .reachedEnd : .idle)
            } catch {
                guard timeline === controller.store.timeline else { return }
                controller.logger.error("profile statuses failed: \(SciaLog.describe(error), privacy: .public)")
                controller.showListFailure(error)
            }
        }
    }

    private func loadOlder() {
        let timeline = store.timeline
        guard !timeline.isLoading, !timeline.reachedEnd, !timeline.isEmpty else { return }
        viewController?.setFooterState(.loading)
        run { controller in
            do {
                guard try await timeline.loadOlder() != nil, timeline === controller.store.timeline else { return }
                controller.showEntries()
                controller.viewController?.setFooterState(timeline.reachedEnd ? .reachedEnd : .idle)
            } catch {
                guard timeline === controller.store.timeline else { return }
                controller.showListFailure(error)
            }
        }
    }

    private func showListFailure(_ error: any Error) {
        handleUnauthorized(error)
        viewController?.setFooterState(.failed(ErrorPresentation(error)))
    }

    private func handleUnauthorized(_ error: any Error) {
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
    }

    private func retry() {
        if store.timeline.isEmpty {
            loadInitial()
        } else {
            loadOlder()
        }
    }

    // MARK: - 一覧の切り替え

    /// 切り替えた一覧を読む。前の一覧は、新しい一覧が届くまで消さずに残す。
    private func select(_ tab: ProfileTab) {
        guard store.select(tab) != nil else { return }
        loadInitial()
    }

    private func changePostsFilter(_ filter: ProfilePostsFilter) {
        settings.profilePostsFilter = filter
        if store.setPostsFilter(filter) != nil {
            loadInitial()
        }
    }

    // MARK: - フォロー

    /// フォローは確かめずに送る。外すときとリクエストを取り消すときは、押し間違えに備えて確かめる。
    private func confirmToggleFollow(from source: UIView) {
        let title: String
        switch store.followState {
        case .notFollowing:
            toggleFollow()
            return
        case .following:
            title = "@\(store.account.acct)のフォローを外しますか？"
        case .requested:
            title = "@\(store.account.acct)へのフォローのリクエストを取り消しますか？"
        case .myself, .unknown, .loadFailed, .blocked:
            return
        }
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: store.followState == .following ? "フォローを外す" : "リクエストを取り消す", style: .destructive) { [weak self] _ in
            self?.toggleFollow()
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        viewController?.frontmostPresented.present(sheet, animated: true)
    }

    private func toggleFollow() {
        run { controller in
            do {
                guard try await controller.store.toggleFollow() else { return }
            } catch {
                controller.logger.error("follow change failed: \(SciaLog.describe(error), privacy: .public)")
                controller.onError(error, "フォローを変更できませんでした")
                return
            }
            do {
                try await controller.store.reloadAccount()
            } catch {
                // フォローは済んでいて、数が古いままなのはサーバーの反映が遅れたときと見分けがつかないため、知らせずに記録だけ残す。
                controller.logger.error("account reload after follow change failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }
}
