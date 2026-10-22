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
    /// ヘッダー画像をバーの下に見せていて、タイトルとスクロールの上端の効果を消している。まだ決めていなければnil。
    private var showsBannerUnderBars: Bool?
    private let settings: AppSettings
    /// フォローの失敗をどう知らせるか。ログインし直しが要るなどの判断はセッションに任せる。
    private let onError: (any Error, String) -> Void
    /// 読み込みが401で失敗したときに呼ぶ。読み込みの失敗はアラートを出さず画面の中に出すため、`onError`とは分ける。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "profile")
    /// 自己紹介か補足情報のリンクを開く。開き方はセッションが決める。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 自分のプロフィールで「プロフィールを編集」を押した。
    var onEditProfile: (() -> Void)?
    private var tasks: [Task<Void, Never>] = []
    /// 表示している一覧と、その一覧のタブ。切り替えた一覧が届くまでは、前の一覧を出し続ける。
    private var shownTimeline: TimelineStore
    private var shownTab: ProfileTab
    /// 開いて最初の一覧を出したか。最初の一覧は、投稿の一覧と固定された投稿の両方が届き、見える行のアイコンを読むのを待ってから、フェードで一度に出す。
    /// 別々に出すと、投稿が2回に分けて現れたり、アイコンが行より遅れて入ったりする。
    private var listReveal = ListReveal.waiting
    /// 最初の一覧に使う投稿の一覧を読み終えた。
    private var isInitialListLoaded = false

    private enum ListReveal {
        case waiting
        /// アイコンを待っている。
        case revealing
        case revealed
    }

    /// 画面とコントローラーを作る。画面が閉じられると、コントローラーも解放される。
    static func make(
        account: Account,
        client: MastodonClient,
        relationshipCache: RelationshipCache,
        settings: AppSettings = AppDependencies.settings,
        onError: @escaping (any Error, String) -> Void,
        onUnauthorized: @escaping () -> Void
    ) -> (ProfileController, TimelineViewController) {
        let viewController = TimelineViewController(texts: .profile)
        let controller = ProfileController(
            account: account,
            client: client,
            relationshipCache: relationshipCache,
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
        relationshipCache: RelationshipCache,
        settings: AppSettings,
        viewController: TimelineViewController,
        onError: @escaping (any Error, String) -> Void,
        onUnauthorized: @escaping () -> Void
    ) {
        store = ProfileStore(
            account: account,
            myAccountID: client.credential.accountID,
            postsFilter: settings.profilePostsFilter,
            relationshipCache: relationshipCache,
            api: ProfileStore.API(client: client)
        )
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
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder() }
        viewController.onRetry = { [weak self] in self?.retry() }
        header.onToggleFollow = { [weak self] source in self?.confirmToggleFollow(from: source) }
        header.onRetryRelationship = { [weak self] in self?.reloadRelationship() }
        header.onEditProfile = { [weak self] in self?.onEditProfile?() }
        header.onSelectTab = { [weak self] tab in self?.select(tab) }
        header.onChangePostsFilter = { [weak self] filter in self?.changePostsFilter(filter) }
        header.onOpenOriginal = { [weak self] in
            guard let url = self?.store.account.url else { return }
            UIApplication.shared.open(url)
        }
        header.onOpenImage = { [weak self] image in self?.openImage(image) }
        header.menuForImage = { [weak self] image in self?.imageMenu(image) }
        header.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination) }
        viewController.onScroll = { [weak self] scrollView in self?.updateBars(scrollView) }
        header.onChangeBannerLayout = { [weak self] in self?.viewController?.headerDidChangeSize() }
        header.onChangeExtendsUnderBars = { [weak self] in
            guard let scrollView = self?.viewController?.collectionView else { return }
            self?.updateBars(scrollView)
        }
        viewController.screenBarItems = [makeUserMenuItem()]
        observeHeaderContent()
        // ヘッダー画像をバーの下に見せる間はタイトルを出さない。最初に出してから消すと、開いた直後にちらつくため、最初から決める。
        viewController.navigationItem.title = header.extendsUnderBars ? nil : "@\(account.acct)"
        // 名前や自己紹介の絵文字が届いたら、ヘッダーを描き直す。投稿の絵文字は一覧が描き直す。
        viewController.emojiImages.addListener(owner: self) { [weak self] urls in
            guard let self, !Set(self.store.account.emojis.map(\.staticUrl)).isDisjoint(with: urls) else { return }
            self.updateHeader()
        }
    }

    /// ヘッダー画像の上を画面の上端まで伸ばす。画像がバーの下に見えている間は、タイトルとスクロールの上端の効果を消して画像を見せ、
    /// ステータスバーの文字を、その下に見えている画像の明るさに合わせて白か黒にする。画像がバーの下に隠れたら戻す。
    private func updateBars(_ scrollView: UIScrollView) {
        guard header.isDescendant(of: scrollView) else { return }
        let statusBarHeight = scrollView.window?.safeAreaInsets.top ?? 0
        header.barHeights = ProfileHeaderView.BarHeights(
            statusBar: statusBarHeight,
            navigationBar: max(scrollView.adjustedContentInset.top - statusBarHeight, 0)
        )
        let headerTop = header.convert(CGPoint.zero, to: scrollView).y
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let pulled = max(-visibleTop, 0)
        header.pulledDistance = pulled
        let extensionHeight = max(headerTop - scrollView.contentOffset.y - pulled, 0)
        if header.topExtension != extensionHeight {
            header.topExtension = extensionHeight
        }
        let shows = header.extendsUnderBars && visibleTop < headerTop + header.bannerBottom
        let statusBar = scrollView.window?.windowScene?.statusBarManager?.statusBarFrame ?? .zero
        viewController?.statusBarStyle = switch shows ? header.textTone(under: statusBar) : nil {
        case .light: .lightContent
        case .dark: .darkContent
        case nil: .default
        }
        guard shows != showsBannerUnderBars else { return }
        showsBannerUnderBars = shows
        viewController?.passesEmptyNavigationBarTaps = shows
        viewController?.navigationItem.title = shows ? nil : "@\(store.account.acct)"
        scrollView.topEdgeEffect.isHidden = shows || MacNavigationBarBackground.isNeeded
    }

    /// ヘッダーに出す値が変わったら描き直す。フォローを送っている途中の表示も、ここで切り替わる。
    private func observeHeaderContent() {
        withObservationTracking {
            updateHeader()
            _ = store.pinned
            _ = store.isPinnedSettled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.afterTransition { controller in
                    controller.observeHeaderContent()
                    controller.showEntries()
                    controller.revealListIfReady()
                }
            }
        }
    }

    /// 画面を移る動きの最中なら、移り終わってから行う。ヘッダーを描き直したり一覧の行を作ったりすると、メインスレッドが100msほど止まる。
    /// 止まっている間も、移り変わりに相乗りする動き（チップの列）は時計どおりに進むため、移り変わりとずれて跳んで見える。
    private func afterTransition(_ work: @escaping @MainActor (ProfileController) -> Void) {
        // 戻り値は相乗りの動きを登録できたかで、completionは登録できなくても呼ばれるため、戻り値で分けない。
        guard let coordinator = viewController?.transitionCoordinator else {
            work(self)
            return
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            work(self)
        }
    }

    func start() {
        // ヘッダーは一覧の区切りに載るため、空の一覧を入れて区切りを作り、画面が移り始める前から出しておく。
        // 読み込みの結果は移り終わるまで待たせるので、ここで入れないと、移る間は何もない画面が流れてくる。
        showEntries()
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
        showEntries(animatesRemoval: true)
    }

    /// ユーザーのメニューで変えた関係を反映する。フォローを変えたら、フォロワー数のためにアカウントを読み直す。
    func apply(_ relationship: Relationship, reloadsAccount: Bool) {
        store.apply(relationship)
        guard reloadsAccount else { return }
        run { controller in
            do {
                try await controller.store.reloadAccount()
            } catch {
                controller.logger.error("account reload after relation change failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 編集して保存した自分のプロフィールを反映する。
    func apply(edited account: Account) {
        store.apply(edited: account)
    }

    /// 開いているプロフィールのアカウントのID。
    var accountID: String { store.account.id }

    /// 固定を変えたあとに、固定された投稿を読み直す。外した投稿は、使う人の操作の結果なので、閉じて詰める動きで消す。
    /// 読めなかったときは、前の固定された投稿のまま残す。固定の操作はできているので、知らせない。
    func reloadPinned() {
        run { controller in
            do {
                try await controller.store.reloadPinned()
                controller.afterTransition { $0.showEntries(animatesRemoval: true) }
            } catch {
                controller.logger.error("profile pinned reload failed: \(SciaLog.describe(error), privacy: .public)")
                controller.handleUnauthorized(error)
            }
        }
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
        header.followRevealDuration = viewController?.tuning.value(of: TuningCatalog.profileRevealDuration) ?? 0
        if let tuning = viewController?.tuning {
            header.reflectionStyle = ProfileBannerBlur.Style(
                blur: tuning.value(of: TuningCatalog.profileBannerReflectionBlur),
                dim: tuning.value(of: TuningCatalog.profileBannerReflectionDim),
                seam: tuning.value(of: TuningCatalog.profileBannerReflectionSeam)
            )
        }
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
            animatesCustomEmojis: settings.animatesCustomEmojis,
            glyphLanguage: settings.glyphLanguageIdentifier(),
            // ローカルのアカウントのacctには@以降が付かない。
            isRemote: account.acct.contains("@")
        ))
        viewController?.headerDidChangeSize()
    }

    /// - Parameter replacing: 一覧を切り替えた。タブを押した場所に残し、その下の中身だけを差し替える。
    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    private func showEntries(replacing: Bool = false, animatesRemoval: Bool = false) {
        viewController?.setEntries(listReveal == .revealed ? shownEntries() : [], keepsOffset: replacing, animatesRemoval: animatesRemoval)
    }

    private func shownEntries() -> [TimelineEntry] {
        let pinned = shownTab == .posts ? store.pinned : []
        return pinned.map(TimelineEntry.pinned) + shownTimeline.entries
    }

    /// 最初の一覧を出せるようになっていたら、見える行のアイコンを上限まで待ってから、フェードで出す。
    /// 「メディア」の一覧には固定された投稿を置かないので、固定された投稿を待たない。
    private func revealListIfReady() {
        guard listReveal == .waiting, isReadyToRevealList else { return }
        listReveal = .revealing
        run { controller in
            guard let viewController = controller.viewController else { return }
            // 1画面に収まる行の数より多めに待つ。全部を待つと、画面の外の行のアイコンまで待たされる。
            let deadline = ContinuousClock.now + .seconds(viewController.tuning.value(of: TuningCatalog.profileAvatarWait))
            await viewController.waitForAvatars(of: { Array(controller.shownEntries().prefix(12)) }, until: deadline)
            controller.afterTransition { controller in
                // 待つ間に「メディア」から「投稿」へ切り替えていたら、固定された投稿がまだのことがある。届いたら、待ち直す。
                guard controller.isReadyToRevealList else {
                    controller.listReveal = .waiting
                    return
                }
                controller.listReveal = .revealed
                controller.showEntries(replacing: true)
                // 待つ間に別の一覧へ切り替えていたら、フッターはその一覧の読み込み中や失敗の表示のまま残す。
                if controller.shownTimeline === controller.store.timeline {
                    controller.viewController?.setFooterState(controller.shownTimeline.reachedEnd ? .reachedEnd : .idle)
                }
                controller.viewController?.fadeInVisibleItems(duration: controller.revealDuration)
            }
        }
    }

    /// 最初の一覧の投稿を読み終え、「投稿」の一覧なら固定された投稿も読み終えた。
    private var isReadyToRevealList: Bool {
        isInitialListLoaded && (shownTab != .posts || store.isPinnedSettled)
    }

    private var revealDuration: TimeInterval {
        guard let viewController else { return 0 }
        return viewController.tuning.value(of: TuningCatalog.profileRevealDuration)
    }

    /// 開いているユーザーのユーザーのメニューを出すボタン。並びの設定を開いている間に変えても反映するよう、押すたびに組む。
    /// 設定ですべての項目を隠していると、空のメニューが出る。ボタンを消すには設定の変化を見張る必要があり、すべて隠すことはまずないため、そのままにする。
    private func makeUserMenuItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"))
        item.accessibilityLabel = "ユーザーのメニュー"
        item.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak item] completion in
            guard let self, let item, let menu = self.viewController?.profileUserMenu(for: self.store.account, from: item) else {
                completion([])
                return
            }
            completion(menu.children)
        }])
        return item
    }

    /// アイコンかヘッダー画像を、添付ファイルと同じビューアで開く。1枚だけを開き、左右に切り替えない。
    private func openImage(_ image: ProfileImage) {
        guard let attachment = store.account.attachment(of: image) else { return }
        viewController?.openMedia([attachment], at: 0, subject: nil) { [weak header] _ in
            header?.viewerSource(for: image)
        }
    }

    /// アイコンかヘッダー画像のメディアのメニュー。投稿がないため「投稿」は出さない。
    private func imageMenu(_ image: ProfileImage) -> UIMenu? {
        guard let attachment = store.account.attachment(of: image), let source = header.viewerSource(for: image) else { return nil }
        let target = TimelineViewController.MediaMenuTarget(attachment: attachment, source: source) { [weak self] in
            self?.openImage(image)
        }
        return viewController?.mediaMenu(for: target, subject: nil, statusMenu: nil)
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
                controller.afterTransition { controller in
                    // 待つ間に別のタブへ切り替えていたら、その一覧の読み込みに任せる。
                    guard timeline === controller.store.timeline else { return }
                    controller.shownTimeline = timeline
                    controller.shownTab = controller.store.tab
                    guard controller.listReveal == .revealed else {
                        // 最初の一覧は、出すときにフッターもまとめて切り替える。
                        controller.isInitialListLoaded = true
                        controller.revealListIfReady()
                        return
                    }
                    controller.showEntries(replacing: true)
                    controller.viewController?.setFooterState(timeline.reachedEnd ? .reachedEnd : .idle)
                }
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
