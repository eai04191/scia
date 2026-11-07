import Observation
import os
import SciaCore
import UIKit

/// プロフィール画面。ProfileStoreの状態を、ヘッダーと投稿のタイムラインへつなぐ。
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
    private let logger = SciaLog.logger(category: "profile")
    /// 自己紹介か補足情報のリンクを開く。開き方はセッションが決める。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 自分のプロフィールで「プロフィールを編集」を押した。
    var onEditProfile: (() -> Void)?
    /// フォローかフォロワーの数が押されたときに、開く人のリストを渡して呼ぶ。
    var onOpenAccountList: ((AccountListKind) -> Void)?
    /// フォローのボタンで、紹介している相手のフォローを外した。サーバーは紹介も消すので、自分のプロフィールの棚を読み直すのに使う。
    var onEndorsementRemoved: (() -> Void)?
    /// この画面が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときと、画面を閉じてこのコントローラーが捨てられたときに閉じる。
    private let tasks: TaskScope
    /// 表示しているタイムラインと、そのタイムラインのタブ。切り替えたタイムラインが届くまでは、前のタイムラインを出し続ける。
    private var shownTimeline: TimelineStore
    private var shownTab: ProfileTab
    /// 開いて最初のタイムラインを出したか。最初のタイムラインは、投稿のタイムラインと固定された投稿の両方が届き、見える行のアイコンを読むのを待ってから、フェードで一度に出す。
    /// 別々に出すと、投稿が2回に分けて現れたり、アイコンが行より遅れて入ったりする。
    private var listReveal = ListReveal.waiting
    /// 最初のタイムラインに使う投稿を読み終えた。
    private var isInitialListLoaded = false
    /// フォローの関係を待つのが長引いている。フォローのボタンの中にアクティビティインジケータを出す。
    private var isRelationshipSlow = false
    /// 開いたときの読み込みを終えた。相手がサーバーの応答に入らなかったときは、関係が分からないまま終わる。
    private var isProfileLoaded = false
    /// タブに置いたプロフィールで、画面が前に出ている。前に出ている間だけ新着を読む。
    private var isShown = false
    private var isInForeground = true
    /// 前に出ている間に新着を読む繰り返し。
    private var pollingTask: Task<Void, Never>?

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
        tasks: TaskScope,
        onError: @escaping (any Error, String) -> Void
    ) -> (ProfileController, TimelineViewController) {
        // 画面を作る時点ではコントローラーがまだないため、作ったあとに入れる。
        weak var owner: ProfileController?
        let viewController = TimelineViewController(texts: .profile) { await owner?.refresh() }
        let controller = ProfileController(
            account: account,
            client: client,
            relationshipCache: relationshipCache,
            settings: settings,
            viewController: viewController,
            tasks: tasks,
            onError: onError
        )
        viewController.lifetimeOwner = controller
        owner = controller
        return (controller, viewController)
    }

    private init(
        account: Account,
        client: MastodonClient,
        relationshipCache: RelationshipCache,
        settings: AppSettings,
        viewController: TimelineViewController,
        tasks: TaskScope,
        onError: @escaping (any Error, String) -> Void
    ) {
        self.tasks = tasks
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
        self.viewController = viewController
        viewController.filterWarnings = FilterWarnings(filtering: store.filtering)
        viewController.headerView = header
        viewController.myAccountID = client.credential.accountID
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(purpose: .display) }
        viewController.onRetry = { [weak self] in self?.retry() }
        // 引っぱって読み直した投稿が多く、手元の投稿との間が残ったときだけギャップの行が出る。読み直しの続きなので、押されたときだけ読む。
        viewController.onGapSelect = { [weak self] id, direction in self?.loadGap(id, from: direction) }
        header.onToggleFollow = { [weak self] source in self?.confirmToggleFollow(from: source) }
        header.onRetryRelationship = { [weak self] in self?.reloadRelationship() }
        header.onEditProfile = { [weak self] in self?.onEditProfile?() }
        header.onEditPrivateNote = { [weak self] in self?.editPrivateNote() }
        header.onOpenCountList = { [weak self] list in
            guard let self else { return }
            let accountID = store.account.id
            onOpenAccountList?(list == .following ? .following(accountID: accountID) : .followers(accountID: accountID))
        }
        header.onSelectTab = { [weak self] tab in self?.select(tab) }
        header.onChangePostsFilter = { [weak self] filter in self?.changePostsFilter(filter) }
        header.onOpenOriginal = { [weak self] in
            guard let url = self?.store.account.url else { return }
            UIApplication.shared.open(url)
        }
        header.onOpenImage = { [weak self] image in self?.openImage(image) }
        header.onOpenPinned = { [weak viewController] status, frame in viewController?.onOpenThread?(status, frame) }
        // 注目のハッシュタグは、ハッシュタグのメニューの「投稿したユーザーの投稿」と同じく、そのプロフィールの人のそのタグの付いた投稿を開く。
        header.onOpenFeaturedTag = { [weak self] tag in
            guard let self else { return }
            self.viewController?.onOpenAccountHashtag?(tag.name, store.account)
        }
        header.menuForFeaturedTag = { [weak self] tag, view in
            guard let self else { return nil }
            return self.viewController?.profileFeaturedTagMenu(for: tag, of: store.account, from: view)
        }
        header.onOpenEndorsed = { [weak viewController] account in viewController?.onOpenProfile?(account) }
        header.menuForEndorsed = { [weak viewController] account, view in viewController?.profileEndorsedUserMenu(for: account, from: view) }
        header.onOpenAllEndorsements = { [weak self] in
            guard let self else { return }
            onOpenAccountList?(.endorsements(accountID: store.account.id))
        }
        header.shelfMenuLifecycle = MenuLifecycle(
            willShow: { [weak viewController] in viewController?.linkMenuWillShow() },
            didHide: { [weak viewController] in viewController?.linkMenuDidHide() }
        )
        header.menuForImage = { [weak self] image, groups in self?.imageMenu(image, groups: groups) }
        header.menuForText = { [weak self] part in
            guard let self, let text = store.account.profileText(part) else { return nil }
            return self.viewController?.profileTextMenu(for: text)
        }
        header.menuForHandle = { [weak self] in
            guard let self else { return nil }
            return self.viewController?.profileHandleMenu(for: store.account)
        }
        header.menuForPrivateNote = { [weak self] in
            guard let self, let note = store.relationship?.note, !note.isEmpty else { return nil }
            return self.viewController?.privateNoteMenu(for: note) { [weak self] in self?.editPrivateNote() }
        }
        header.textMenuLifecycle = MenuLifecycle(
            willShow: { [weak viewController] in viewController?.linkMenuWillShow() },
            didHide: { [weak viewController] in viewController?.linkMenuDidHide() }
        )
        header.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination) }
        viewController.onScroll = { [weak self] scrollView in self?.updateBars(scrollView) }
        header.onChangeBannerLayout = { [weak self] in self?.viewController?.headerDidChangeSize() }
        header.onExpandNote = { [weak self] duration in self?.viewController?.headerDidChangeSize(animatingWithDuration: duration) }
        header.onChangeScreenTint = { [weak self] color in
            self?.viewController?.view.tintColor = color
        }
        header.onChangeExtendsUnderBars = { [weak self] in
            guard let scrollView = self?.viewController?.collectionView else { return }
            self?.updateBars(scrollView)
        }
        viewController.screenBarItems = [makeUserMenuItem()]
        observeHeaderContent()
        // ヘッダー画像をバーの下に見せる間はタイトルを出さない。最初に出してから消すと、開いた直後にちらつくため、最初から決める。
        viewController.navigationItem.title = header.extendsUnderBars ? nil : "@\(account.acct)"
        // 名前や自己紹介の絵文字が届いたら、ヘッダーを描き直す。投稿の絵文字はタイムラインが描き直す。
        // 画面に出ていない間に届いた知らせは、出たときに描き直す（`addListener(whileShownIn:onLoad:)`）。
        viewController.emojiImages.addListener(whileShownIn: header) { [weak self] urls in
            self?.emojiImagesDidLoad(urls)
        }
    }

    private func emojiImagesDidLoad(_ urls: Set<URL>) {
        // 固定された投稿はタイムラインの行ではなく棚に並べるので、タイムラインの描き直しでは描き直されない。棚のカードもここで描き直す。
        if header.redrawPinned(ifUsing: urls) {
            viewController?.headerDidChangeSize()
        }
        if header.redrawEndorsements(ifUsing: urls) {
            viewController?.headerDidChangeSize()
        }
        guard !Set(store.account.emojis.map(\.staticUrl)).isDisjoint(with: urls) else { return }
        updateHeader()
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
            _ = store.featuredTags
            _ = store.endorsements
            _ = store.isShelvesSettled
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.afterTransition { controller in
                    controller.observeHeaderContent()
                    controller.showEntries()
                    controller.revealListIfReady()
                }
            }
        }
    }

    /// 画面を移る動きの最中なら、移り終わってから行う。ヘッダーを描き直したりタイムラインの行を作ったりすると、メインスレッドが100msほど止まる。
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
        // ヘッダーはタイムラインの区切りに載るため、空のタイムラインを入れて区切りを作り、画面が移り始める前から出しておく。
        // 読み込みの結果は移り終わるまで待たせるので、ここで入れないと、移る間は何もない画面が流れてくる。
        showEntries()
        loadProfile()
        loadInitial()
        waitForRelationship()
    }

    /// 開いたときにフォローの関係がまだなければ、少し待っても届かないときだけ、フォローのボタンの中にインジケータを出す。
    /// 一度読んだ関係は覚えているので、開き直したときは待たない。
    private func waitForRelationship() {
        guard store.followState == .unknown, let viewController else { return }
        let clock = viewController.clock
        let delay = viewController.tuning.value(of: TuningCatalog.profileRelationshipActivityDelay)
        run(.action) { controller in
            guard (try? await clock.sleep(for: .seconds(delay))) != nil, controller.store.followState == .unknown, !controller.isProfileLoaded else { return }
            controller.isRelationshipSlow = true
            controller.afterTransition { $0.updateHeader() }
        }
    }

    /// 投稿への操作の結果を、固定された投稿とタイムラインに反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿を、固定された投稿とタイムラインから除く。
    func removeStatus(_ id: Status.ID) {
        guard store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ユーザーのメニューで変えた関係を反映する。フォローを変えたら、フォロワー数のためにアカウントを読み直す。
    func apply(_ relationship: Relationship, reloadsAccount: Bool) {
        store.apply(relationship)
        guard reloadsAccount else { return }
        run(.action) { controller in
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

    // MARK: - 前に出ている間の読み直し

    /// タブに置いたプロフィールで、前に出ている間は間隔をおいて新着を読む。アカウントの投稿のストリームはないため。
    /// 見ていない間は読まず、見えたときとアプリに戻ったときに、見ていなかった間の新着を読む。決まりはdocs/tabs.mdの「プロフィール」にある。
    func readsNewWhileShown() {
        viewController?.onVisibilityChange = { [weak self] isShown in self?.setShown(isShown) }
    }

    private func setShown(_ isShown: Bool) {
        guard self.isShown != isShown else { return }
        self.isShown = isShown
        restartPolling()
    }

    func enterForeground() {
        isInForeground = true
        restartPolling()
    }

    func enterBackground() {
        isInForeground = false
        restartPolling()
    }

    /// 前に出ていれば、すぐ新着を読み、そのあとは間隔をおいて読む。前に出ていなければやめる。
    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isShown, isInForeground, let viewController else { return }
        let clock = viewController.clock
        let tuning = viewController.tuning
        // 使う人の操作によらず送るので、レート制限で止められている間は送らない。
        pollingTask = run(.display) { controller in
            await controller.readNew()
            while !Task.isCancelled {
                guard (try? await clock.sleep(for: .seconds(tuning.value(of: TuningCatalog.shownFeedPollingInterval)))) != nil else { return }
                controller.logger.info("profile poll while shown")
                await controller.readNew()
            }
        }
    }

    /// 見ているタイムラインの、一番新しい投稿より後の投稿を読んで足す。空のタイムラインなら、最新のページを読む。最初のタイムラインを出す前は、その読み込みに任せる。
    /// 読めなかったことは画面に出さない。次の読み直しか、引っぱって読み直したときに読む。
    private func readNew() async {
        let timeline = store.timeline
        guard listReveal == .revealed, timeline === shownTimeline, let viewController else { return }
        // 最初のタイムラインを読めていなければ、フッターのやり直しに任せる。
        if timeline.isEmpty, case .failed = viewController.footerState { return }
        let wasEmpty = timeline.isEmpty
        do {
            let maxPages = Int(viewController.tuning.value(of: TuningCatalog.fillPageLimit))
            guard let added = try await timeline.fillFromLatest(maxPages: maxPages), timeline === store.timeline else { return }
            logger.info("profile read new added=\(added.count, privacy: .public) gaps=\(timeline.gaps.count, privacy: .public)")
            if wasEmpty {
                viewController.setFooterState(timeline.reachedEnd ? .reachedEnd : .idle)
            }
        } catch {
            guard !(error is CancellationError) else { return }
            logger.error("profile read new failed: \(SciaLog.describe(error), privacy: .public)")
        }
        showGapStates()
        showEntries()
    }

    /// 固定を変えたあとに、固定された投稿を読み直す。外した投稿は、使う人の操作の結果なので、閉じて詰める動きで消す。
    /// 読めなかったときは、前の固定された投稿のまま残す。固定の操作はできているので、知らせない。
    func reloadPinned() {
        run(.action) { controller in
            do {
                try await controller.store.reloadPinned()
                controller.afterTransition { $0.showEntries(animatesRemoval: true) }
            } catch {
                controller.logger.error("profile pinned reload failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 載せるものを変えたあとに、注目のハッシュタグと紹介しているユーザーを読み直す。外したものは、使う人の操作の結果なので、閉じて詰める動きで消す。
    /// 読めなかったときは、前の棚のまま残す。載せる操作はできているので、知らせない。
    func reloadFeatured() {
        run(.action) { controller in
            do {
                try await controller.store.reloadFeatured()
                controller.afterTransition { $0.showEntries() }
            } catch {
                controller.logger.error("profile featured reload failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    @discardableResult
    private func run(_ purpose: RequestPurpose, _ operation: @escaping @MainActor (ProfileController) async -> Void) -> Task<Void, Never>? {
        tasks.run(purpose) { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    /// 走り終えていない処理の数。閉じたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { tasks.runningCount }

    private func updateHeader() {
        let account = store.account
        header.followRevealDuration = viewController?.tuning.value(of: TuningCatalog.profileRevealDuration) ?? 0
        if let tuning = viewController?.tuning {
            header.reflectionStyle = ProfileBannerBlur.Style(
                blur: tuning.value(of: TuningCatalog.profileBannerReflectionBlur),
                dim: tuning.value(of: TuningCatalog.profileBannerReflectionDim),
                seam: tuning.value(of: TuningCatalog.profileBannerReflectionSeam)
            )
            header.countsSpacing = tuning.value(of: TuningCatalog.profileCountsSpacing)
            header.noteFadeWidth = tuning.value(of: TuningCatalog.profileNoteFadeWidth)
            header.noteExpandDuration = tuning.value(of: TuningCatalog.profileNoteExpandDuration)
            header.accentOptions = ProfileCardPalette.Options(tuning: tuning)
            header.accentFadeDuration = tuning.value(of: TuningCatalog.profileAccentFadeDuration)
        }
        header.apply(ProfileHeaderView.Content(
            account: account,
            followState: store.followState,
            followedBy: store.relationship?.followedBy ?? false,
            isChangingFollow: store.isChangingFollow,
            isReloadingRelationship: store.isReloadingRelationship,
            showsRelationshipActivity: isRelationshipSlow,
            tab: store.tab,
            postsFilter: store.postsFilter,
            avatarShape: settings.appearance.avatarShape,
            animatesAvatar: settings.animatesAvatars,
            animatesCustomEmojis: settings.animatesCustomEmojis,
            glyphLanguage: settings.glyphLanguageIdentifier(),
            // ローカルのアカウントのacctには@以降が付かない。
            isRemote: account.acct.contains("@"),
            privateNote: store.relationship?.note ?? "",
            avatarDescription: attachment(of: .avatar)?.description,
            headerDescription: attachment(of: .header)?.description
        ))
        viewController?.headerDidChangeSize()
    }

    /// - Parameter replacing: タイムラインを切り替えた。タブを押した場所に残し、その下の中身だけを差し替える。
    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    private func showEntries(replacing: Bool = false, animatesRemoval: Bool = false) {
        // 固定された投稿の棚とその下のタブは、タイムラインと一緒に出す。棚はタブより上にあるので、どちらのタブでも出す。
        let isRevealed = listReveal == .revealed
        // 一度出したら隠し直さない。最初のタイムラインを読めなかったときは、タイムラインより先にタブを出している（`showListFailure`）。
        let changesSections = isRevealed && header.setSectionsRevealed(true)
        // 棚にも、タイムラインの行と同じサーバーのフィルターの警告とぼかしを当てる。
        let items = { (statuses: [Status]) in statuses.map { ProfileShelfItem(status: $0, verdict: self.store.filtering.verdict(for: $0)) } }
        let changesPinned = header.setPinned(isRevealed ? items(store.pinned) : [], glyphLanguage: settings.glyphLanguageIdentifier())
        let changesFeatured = header.setFeatured(
            tags: isRevealed ? store.featuredTags : [],
            endorsements: ProfileEndorsementsShelfView.Content(
                accounts: isRevealed ? store.endorsements : [],
                hasMore: store.hasMoreEndorsements,
                avatarShape: settings.appearance.avatarShape,
                animatesAvatars: settings.animatesAvatars,
                animatesCustomEmojis: settings.animatesCustomEmojis,
                glyphLanguage: settings.glyphLanguageIdentifier()
            )
        )
        if changesSections || changesPinned || changesFeatured {
            viewController?.headerDidChangeSize()
        }
        viewController?.setEntries(listReveal == .revealed ? shownEntries() : [], keepsOffset: replacing, animatesRemoval: animatesRemoval)
    }

    private func shownEntries() -> [TimelineEntry] {
        shownTimeline.entries
    }

    /// 最初のタイムラインを出せるようになっていたら、見える行のアイコンを上限まで待ってから、フェードで出す。
    /// 「メディア」のタイムラインには固定された投稿を置かないので、固定された投稿を待たない。
    private func revealListIfReady() {
        guard listReveal == .waiting, isReadyToRevealList else { return }
        listReveal = .revealing
        run(.display) { controller in
            guard let viewController = controller.viewController else { return }
            // 1画面に収まる行の数より多めに待つ。全部を待つと、画面の外の行のアイコンまで待たされる。
            let wait = Duration.seconds(viewController.tuning.value(of: TuningCatalog.profileAvatarWait))
            await viewController.waitForAvatars(of: { Array(controller.shownEntries().prefix(12)) }, within: wait)
            controller.afterTransition { controller in
                // 待つ間に「メディア」から「投稿」へ切り替えていたら、固定された投稿がまだのことがある。届いたら、待ち直す。
                guard controller.isReadyToRevealList else {
                    controller.listReveal = .waiting
                    return
                }
                controller.listReveal = .revealed
                controller.showEntries(replacing: true)
                // 待つ間に別のタイムラインへ切り替えていたら、フッターはそのタイムラインの読み込み中や失敗の表示のまま残す。
                if controller.shownTimeline === controller.store.timeline {
                    controller.viewController?.setFooterState(controller.shownTimeline.reachedEnd ? .reachedEnd : .idle)
                }
                controller.viewController?.fadeInVisibleItems(duration: controller.revealDuration)
                controller.header.fadeInSections(duration: controller.revealDuration)
            }
        }
    }

    /// 最初のタイムラインの投稿と、ヘッダーの棚を読み終えた。棚が後から現れて、タブとタイムラインを押し下げないようにするため。
    private var isReadyToRevealList: Bool {
        isInitialListLoaded && store.isShelvesSettled
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
        guard let attachment = attachment(of: image) else { return }
        viewController?.openMedia([attachment], at: 0, subject: nil) { [weak header] _ in
            header?.viewerSource(for: image)
        }
    }

    /// 説明にならない代替テキストは、タイムラインの添付ファイルと同じく、ビューアにもメニューにも出さないよう除いておく。
    private func attachment(of image: ProfileImage) -> MediaAttachment? {
        store.account.attachment(of: image)?.filteringAltText(ignoresUseless: settings.ignoresUselessAltText)
    }

    /// アイコンかヘッダー画像のメディアのメニュー。投稿がないため「投稿」は出さない。
    private func imageMenu(_ image: ProfileImage, groups: MenuLayout<MediaMenuItem>.Groups?) -> BuiltMenu<MediaMenuCommand>? {
        guard let attachment = attachment(of: image), let source = header.viewerSource(for: image) else { return nil }
        let target = TimelineViewController.MediaMenuTarget(attachment: attachment, source: source) { [weak self] in
            self?.openImage(image)
        }
        return viewController?.builtMediaMenu(for: target, subject: nil, statusMenu: nil, groups: groups)
    }

    // MARK: - 読み込み

    /// 読めなかったものはアラートにしない。関係はフォローのボタンの場所で知らせ、アカウントと固定された投稿は、開いた時点の内容のままにしてログだけ残す。
    private func loadProfile() {
        run(.action) { controller in
            let failures = await controller.store.loadProfile()
            controller.finishWaitingForRelationship()
            for (part, error) in failures.all {
                controller.logger.error("profile \(part, privacy: .public) load failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 読み込みを終えたら、インジケータを消す。相手がサーバーの応答に入らなかった（凍結や削除の予定で、Mastodonが返さない）ときは、
    /// 関係は分からないまま残るので、読み込み中を示し続けないよう、ここで消す。
    private func finishWaitingForRelationship() {
        isProfileLoaded = true
        guard isRelationshipSlow else { return }
        isRelationshipSlow = false
        afterTransition { $0.updateHeader() }
    }

    /// 自分にしか見えないメモの欄を押したら、ユーザーのメニューの「メモを編集」と同じシートを開く。
    private func editPrivateNote() {
        guard let relationship = store.relationship else { return }
        let account = store.account
        viewController?.userMenuActions?.editNote(UserRelation(accountID: account.id, acct: account.acct, relationship: relationship))
    }

    /// フォローのボタンの場所の再試行。失敗したら、読めなかった表示のまま残す。
    private func reloadRelationship() {
        run(.action) { controller in
            do {
                try await controller.store.reloadRelationship()
            } catch {
                controller.logger.error("profile relationship reload failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    @discardableResult
    private func loadInitial() -> Task<Void, Never>? {
        let timeline = store.timeline
        viewController?.setFooterState(.loading)
        return run(.action) { controller in
            do {
                guard try await timeline.loadInitial() != nil, timeline === controller.store.timeline else { return }
                controller.afterTransition { controller in
                    // 待つ間に別のタブへ切り替えていたら、そのタイムラインの読み込みに任せる。
                    guard timeline === controller.store.timeline else { return }
                    controller.shownTimeline = timeline
                    controller.shownTab = controller.store.tab
                    guard controller.listReveal == .revealed else {
                        // 最初のタイムラインは、出すときにフッターもまとめて切り替える。
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

    /// - Parameter purpose: 末尾が近づいて読むときは`.display`。再試行を押したときは`.action`。
    private func loadOlder(purpose: RequestPurpose) {
        let timeline = store.timeline
        guard !timeline.isLoading, !timeline.reachedEnd, !timeline.isEmpty else { return }
        viewController?.setFooterState(.loading)
        run(purpose) { controller in
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

    /// タイムラインを引っぱって離したときに、アカウントと固定された投稿を読み直し、一番新しい投稿より後の投稿を上に足す。
    /// タイムラインをまだ読めていなければ、最初の読み込みをやり直す。読めたタイムラインが空なら、最新のページを読む。
    private func refresh() async {
        guard let viewController else { return }
        logger.info("profile refresh")
        let timeline = store.timeline
        if timeline.isEmpty, case .failed = viewController.footerState {
            // 最初のタイムラインを読めていないと、タイムラインを出す前なので、ほかは読み直さずに最初の読み込みをやり直す。
            await loadInitial()?.value
            return
        }
        // 最初のタイムラインを出している途中は、その読み込みに任せる。
        guard listReveal == .revealed else { return }
        async let profile: Void = refreshProfile()
        let wasEmpty = timeline.isEmpty
        do {
            let maxPages = Int(viewController.tuning.value(of: TuningCatalog.fillPageLimit))
            if let added = try await timeline.fillFromLatest(maxPages: maxPages), timeline === store.timeline {
                logger.info("profile refresh done added=\(added.count, privacy: .public) gaps=\(timeline.gaps.count, privacy: .public)")
                if wasEmpty {
                    viewController.setFooterState(timeline.reachedEnd ? .reachedEnd : .idle)
                }
            }
        } catch {
            // 読めなかったことは、タイムラインの上の読み直しなので画面に出さない。前のタイムラインのまま残す。
            logger.error("profile refresh failed: \(SciaLog.describe(error), privacy: .public)")
        }
        await profile
        showGapStates()
        showEntries()
    }

    private func refreshProfile() async {
        let failures = await store.loadProfile()
        for (part, error) in failures.all {
            logger.error("profile refresh \(part, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        }
    }

    private func loadGap(_ id: String, from direction: TimelineStore.GapDirection) {
        let timeline = store.timeline
        guard timeline === shownTimeline, !timeline.loadingGapIDs.contains(id) else { return }
        let entries = shownEntries()
        guard let index = entries.firstIndex(where: { $0.id == .gap(id) }) else { return }
        let neighborIndex = direction == .fromOlder ? entries.index(after: index) : entries.index(before: index)
        let anchorID = entries.indices.contains(neighborIndex) ? entries[neighborIndex].id : nil
        viewController?.setGapStates(loading: timeline.loadingGapIDs.union([id]), failures: timeline.gapFailures.filter { $0.key != id })
        run(.action) { controller in
            do {
                let added = try await timeline.loadGap(id, from: direction)
                guard timeline === controller.store.timeline else { return }
                controller.showGapStates()
                guard added != nil else { return }
                controller.viewController?.setEntries(controller.shownEntries(), keeping: anchorID)
            } catch {
                guard timeline === controller.store.timeline else { return }
                controller.logger.error("profile gap failed: \(SciaLog.describe(error), privacy: .public)")
                controller.showGapStates()
            }
        }
    }

    private func showGapStates() {
        viewController?.setGapStates(loading: shownTimeline.loadingGapIDs, failures: shownTimeline.gapFailures)
    }

    private func showListFailure(_ error: any Error) {
        viewController?.setFooterState(.failed(ErrorPresentation(error)))
        // タブはタイムラインと一緒に出すが、最初のタイムラインを読めなかったときも出し、ほかのタブへ切り替えられるようにする。
        if header.setSectionsRevealed(true) {
            viewController?.headerDidChangeSize()
        }
    }

    private func retry() {
        if store.timeline.isEmpty {
            loadInitial()
        } else {
            loadOlder(purpose: .action)
        }
    }

    // MARK: - タイムラインの切り替え

    /// 切り替えたタイムラインを読む。前のタイムラインは、新しいタイムラインが届くまで消さずに残す。
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

    /// フォローは確かめずに送る。外すときとリクエストを取り消すときは、押し間違えに備えて、ユーザーのメニューと同じ文言で確かめる。
    private func confirmToggleFollow(from source: UIView) {
        guard let change = store.followState.toggleChange else { return }
        guard let confirmation = Confirmation.relationChange(change, acct: store.account.acct, endorsed: store.relationship?.endorsed ?? false) else {
            toggleFollow()
            return
        }
        let sheet = UIAlertController(confirmation, preferredStyle: .actionSheet) { [weak self] _ in
            self?.toggleFollow()
        }
        sheet.popoverPresentationController?.sourceView = source
        // フォローのボタンは、いちばん長い文字の幅で枠を取り、カプセルを右端に寄せて描くので、カプセルを指す。
        if let button = source as? ProfileFollowButton {
            sheet.popoverPresentationController?.sourceRect = button.capsuleFrame
        }
        viewController?.frontmostPresented.present(sheet, animated: true)
    }

    private func toggleFollow() {
        run(.action) { controller in
            let wasEndorsed = controller.store.relationship?.endorsed == true
            do {
                guard try await controller.store.toggleFollow() else { return }
                if wasEndorsed, controller.store.relationship?.endorsed != true {
                    controller.onEndorsementRemoved?()
                }
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

/// プロフィールの投稿はSciaCoreのモデルを持たず、ここで`ProfileStore`を描くので、このコントローラーを一覧として登録する。
extension ProfileController: SessionStatusList {}
