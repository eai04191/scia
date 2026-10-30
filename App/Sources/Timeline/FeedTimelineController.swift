import Foundation
import os
import SciaCore
import UIKit

/// ホームや公開タイムラインの画面を組み立て、読み込みとストリーミングを受け持つ`FeedTimelineModel`とTimelineViewControllerをつなぐ。
/// タブの一覧のほか、開いた一覧に積むハッシュタグの一覧にも使う。
@MainActor
final class FeedTimelineController {
    private(set) lazy var viewController = TimelineViewController(texts: texts) { [weak model] in await model?.refresh() }
    private let texts: TimelineViewController.Texts
    /// 読み込み、ストリーミング、既読位置を受け持つ。
    let model: FeedTimelineModel
    var feed: TimelineFeed { model.feed }
    private let client: MastodonClient
    private let tuning: TuningStore
    private let logger = SciaLog.logger(category: "timeline")
    /// 走り終えていない読み込みなどの処理の数。止めたものも、取り消しを受けて戻り切るまで数える。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }
    /// 一覧のストリームを購読している。
    var isSubscribedToStreaming: Bool { model.isSubscribedToStreaming }
    /// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態。
    private let streamingStatusView = StreamingStatusPullView()
    #if DEBUG
    /// ダミー投稿の「ステータスバーの通知」が選ばれたとき。通知はホームの一覧ではなく、ステータスバーに流す。
    var onDummyNotifications: (() -> Void)?
    /// デバッグメニューの「ステータスバーの通知を出し続ける」を切り替えたとき。渡す値は切り替えたあとの状態。
    var onSetStatusBarTickerLooping: ((Bool) -> Void)?
    /// ステータスバーの通知を出し続けているか。デバッグメニューのチェックマークに使う。
    var isStatusBarTickerLooping: (() -> Bool)?
    #endif
    /// 走っている補完が終わるのを待っている、引っぱった読み直しの数。テストで、待ち始めたことを時間を待たずに確かめる。
    var fillWaiterCount: Int { model.fillWaiterCount }

    init(
        feed: TimelineFeed,
        texts: TimelineViewController.Texts? = nil,
        client: MastodonClient,
        streamingHub: StreamingHub,
        tuning: TuningStore = AppDependencies.tuning,
        clock: any Clock<Duration> = AppDependencies.clock,
        now: @escaping () -> Date = AppDependencies.now,
        tasks: TaskScope,
        onUnauthorized: @escaping () -> Void
    ) {
        model = FeedTimelineModel(
            feed: feed,
            client: client,
            streamingHub: streamingHub,
            tuning: tuning,
            clock: clock,
            now: now,
            backgroundTime: BackgroundTime.request,
            tasks: tasks,
            onUnauthorized: onUnauthorized
        )
        self.texts = texts ?? Self.texts(for: feed)
        self.client = client
        self.tuning = tuning
        model.display = viewController
        model.streamingStatus = streamingStatusView
        #if DEBUG
        model.isHoldingArrivals = { DebugFaults.isHoldingArrivals }
        #endif
        viewController.filterWarnings = FilterWarnings(filtering: model.filtering)
        viewController.onApproachingEnd = { [weak model] in model?.approachEnd() }
        viewController.onRetry = { [weak model] in model?.retry() }
        viewController.onVisibleStatusesChange = { [weak model] ids in model?.markRead(ids) }
        viewController.onInteractionSettle = { [weak model] in model?.interactionDidSettle() }
        streamingStatusView.install(in: viewController.collectionView)
        viewController.onGapSelect = { [weak model] id, direction in model?.selectGap(id, from: direction) }
        viewController.onGapApproach = { [weak model] id, direction in model?.approachGap(id, from: direction) }
        if feed.isAccountHashtag {
            viewController.onVisibilityChange = { [weak model] isShown in model?.setShown(isShown) }
        }
        #if DEBUG
        viewController.debugActions = makeDebugActions()
        #endif
        // モデルが購読をやめたあとに呼ぶよう、モデルを作ったあとに登録する。持ち主は登録した順に呼ぶ。
        tasks.onClose { [weak viewController] in
            // 積んで開いた一覧は、画面がこのコントローラーを生かしているため、持ち合いを解いて捨てられるようにする。
            viewController?.lifetimeOwner = nil
        }
    }

    /// - Parameter purpose: 電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    func start(purpose: RequestPurpose = .action) {
        model.start(purpose: purpose)
    }

    private static func texts(for feed: TimelineFeed) -> TimelineViewController.Texts {
        switch feed {
        case .home: .home
        case .local: .local
        case .federated: .federated
        // リストの名前は、作る側が`texts`で渡す。
        case .list: .list(title: "")
        case .hashtag(let name): .hashtag(name: name)
        // ユーザーの名前は、作る側が`texts`で渡す。
        case .accountHashtag(_, let name): .accountHashtag(name: name, acct: "")
        }
    }

    /// まだ始めていなければ始める。開くまで読まない一覧を、初めて開いたときに始めるのに使う。
    func startIfNeeded() {
        model.startIfNeeded()
    }

    #if DEBUG
    /// 始めている一覧だけ読み込み直す。障害を起こすデバッグURLで、開いたことのない一覧まで読み始めないようにする。
    func reloadIfStarted() {
        model.reloadIfStarted()
    }
    #endif

    /// 設定で有効か無効かを切り替える。
    func setEnabled(_ isEnabled: Bool) {
        model.setEnabled(isEnabled)
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときと、積んで開いた一覧がナビゲーションから外されたときに呼ぶ。
    /// セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    func stop() {
        model.stop()
    }

    /// バックグラウンドに入るときに呼ぶ。
    func enterBackground() {
        model.enterBackground()
    }

    /// バックグラウンドから戻ったときに呼ぶ。
    func enterForeground() {
        model.enterForeground()
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。
    func recover() {
        model.recover()
    }

    /// ストリーミングの接続の状態を、引っぱったときに見せる表示へ伝える。
    func showStreamingState(_ state: ConnectionDiagnostics.StreamingState?) {
        model.showStreamingState(state)
    }

    /// 投稿の応答で返った自分の投稿を、ストリーミングで届くのを待たずに新着と同じ経路で流す。
    func receivePosted(_ status: Status) {
        model.receivePosted(status)
    }

    #if DEBUG
    /// `scia-debug://arrivals/release`で保留を解いたとき。
    func releaseHeldArrivals() {
        model.releaseHeldArrivals()
    }
    #endif

    /// お気に入りなどの操作の結果を反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        model.updateStatus(id, transform)
    }

    /// 削除した投稿と、それをブーストした投稿を除く。
    func removeStatus(_ id: Status.ID) {
        model.removeStatus(id)
    }

    /// ミュートしたハッシュタグの付いた投稿とブーストを除く。
    func setTag(_ name: String, excluded: Bool) {
        model.setTag(name, excluded: excluded)
    }

    /// ミュートかブロックした相手の投稿とブーストを除く。
    func setAccount(_ id: String, excluded: Bool) {
        model.setAccount(id, excluded: excluded)
    }
}

#if DEBUG
// MARK: - 検証用

extension FeedTimelineController {
    /// 投稿しなくても、新着の挿入やギャップの表示をシミュレーターで確かめるための操作。
    fileprivate func makeDebugActions() -> [UIMenuElement] {
        let dummyPosts = DebugDummyPost.MenuGroup.allCases.map { group in
            UIMenu(title: group.title, options: .displayInline, children: DebugDummyPost.allCases.filter { $0.menuGroup == group }.map { post in
                UIAction(title: post.title, image: UIImage(systemName: post.systemImage)) { [weak self] _ in
                    self?.streamDummy(post)
                }
            })
        }
        return [
            UIMenu(title: "ダミー投稿を流す", image: UIImage(systemName: "square.stack"), children: dummyPosts),
            UIMenu(title: "ステータスバーの通知", image: UIImage(systemName: "bell.badge"), children: [
                UIAction(title: "続けざまに流す", image: UIImage(systemName: "bell.badge")) { [weak self] _ in
                    self?.streamDummy(.notifications)
                },
                // オンとオフのチェックマークを、開くたびに今の状態で出す。
                UIDeferredMenuElement.uncached { [weak self] completion in
                    let isOn = self?.isStatusBarTickerLooping?() ?? false
                    completion([
                        UIAction(title: "出し続ける", image: UIImage(systemName: "repeat"), state: isOn ? .on : .off) { [weak self] _ in
                            self?.onSetStatusBarTickerLooping?(!isOn)
                        },
                    ])
                },
            ]),
            UIAction(title: "直近の投稿を取りこぼして再接続", image: UIImage(systemName: "bolt.horizontal")) { [weak self] _ in
                self?.simulateMissedWhileDisconnected()
            },
        ]
    }

    /// サーバーにない検証用の投稿か。リンクカードの取り直しから外すために使う。
    func isDebugLocalOnly(_ id: Status.ID) -> Bool {
        model.debugStore.debugLocalOnlyIDs.contains(id)
    }

    /// `scia-debug://inject/home`で読んだ投稿を、新着と同じ経路で流す。サーバーにない投稿なので、既読位置には使わない。
    func inject(_ statuses: [Status]) {
        logger.info("debug inject home count=\(statuses.count, privacy: .public)")
        for status in statuses {
            model.debugStore.debugLocalOnlyIDs.insert(status.id)
            model.debugReceive(.update(status))
        }
    }

    /// デバッグメニューや、URLで指定したダミー投稿を流す。
    func streamDummy(_ post: DebugDummyPost) {
        logger.info("debug stream dummy \(post.rawValue, privacy: .public)")
        switch post {
        case .arrivals:
            streamDummyArrivals(count: 10)
        case .images:
            streamDummyMediaStatus(content: "ビューアの確認用に4枚の画像を添付", attachments: DummyMedia.attachments)
        case .tall:
            streamDummyMediaStatus(content: "ビューアの確認用に縦長の画像を1枚添付", attachments: DummyMedia.singleTallAttachment)
        case .small:
            streamDummyMediaStatus(content: "ビューアの確認用に画面より小さい画像を3枚添付", attachments: DummyMedia.smallAttachments)
        case .transparent:
            streamDummyMediaStatus(content: "ビューアの確認用に透明な部分のある画像を1枚添付", attachments: DummyMedia.singleTransparentAttachment)
        case .video:
            streamDummyVideoStatus(content: "ビューアの確認用に動画とGIFを1本ずつ添付", make: DummyMedia.videoAttachments)
        case .longVideo:
            streamDummyVideoStatus(content: "ビューアの確認用に、無音の音声トラックが付いた90秒の動画を添付", make: DummyMedia.longVideoAttachment)
        case .linkCard:
            streamDummyLinkCard(withImage: false)
        case .linkCardImage:
            streamDummyLinkCard(withImage: true)
        case .linkCardSensitive:
            streamDummyLinkCard(withImage: true, sensitive: true)
        case .xPost:
            streamDummyXPost()
        case .filtered:
            streamDummyFiltered()
        case .animatedEmojis:
            streamDummyAnimatedEmojis()
        case .polls:
            streamDummyPolls()
        case .quotes:
            streamDummyQuotes()
        case .notifications:
            onDummyNotifications?()
        }
    }

    /// サーバーのフィルターに一致したダミーの投稿を、新着と同じ経路で流す。警告、警告と注意書き、添付ファイルのぼかし、隠すの4件。
    /// 隠す投稿は一覧に出ないので、3件だけ並べば合っている。実際にフィルターを作らずに、何度でも同じ条件で確かめるため。
    private func streamDummyFiltered() {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        func filter(_ title: String, _ action: FilterResult.Action) -> [FilterResult] {
            [FilterResult(filter: FilterResult.Filter(id: "dummy-\(title)", title: title, context: [feed.filterContext], filterAction: action), keywordMatches: [title])]
        }
        let posts: [(content: String, spoilerText: String, filtered: [FilterResult], media: Bool)] = [
            ("警告のフィルターに一致したダミーの投稿", "", filter("ダミーの警告", .warn), false),
            ("警告のフィルターと注意書きのあるダミーの投稿", "ダミーの注意書き", filter("ダミーの警告", .warn), false),
            ("添付ファイルをぼかすフィルターに一致したダミーの投稿", "", filter("ダミーのぼかし", .blur), true),
            ("隠すフィルターに一致したダミーの投稿。一覧に出たら誤り", "", filter("ダミーの非表示", .hide), false),
        ]
        model.debugRun { model in
            for (index, post) in posts.enumerated() {
                guard !model.isStopped else { return }
                let base = Self.dummyStatus(number: index + 1, avatar: avatar, now: model.now())
                let dummy = Status(
                    id: base.id,
                    createdAt: base.createdAt,
                    account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（フィルター）", avatar: avatar),
                    content: "<p>\(post.content)</p>",
                    spoilerText: post.spoilerText,
                    url: nil,
                    mediaAttachments: post.media ? DummyMedia.attachments(idPrefix: base.id) : [],
                    filtered: post.filtered
                )
                model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
                model.debugReceive(.update(dummy))
            }
        }
    }

    /// 投票の付いたダミーの投稿を、新着と同じ経路で流す。複数選べない投票、複数選べる投票、締め切るまで票数を隠す投票、締め切った投票の4件。
    /// 投票と読み直しは通信せず、`DummyPolls`が答える。
    private func streamDummyPolls() {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        func poll(_ key: String, multiple: Bool = false, expiresIn: TimeInterval = 86_400, options: [(String, Int?)], votesCount: Int? = nil, votersCount: Int? = nil) -> Poll {
            Poll(
                id: DummyPolls.idPrefix + key + "-\(UInt64(model.now().timeIntervalSince1970 * 1000))",
                expiresAt: model.now().addingTimeInterval(expiresIn),
                expired: expiresIn < 0,
                multiple: multiple,
                votesCount: votesCount ?? options.compactMap(\.1).reduce(0, +),
                votersCount: multiple ? votersCount : nil,
                options: options.map { Poll.Option(title: $0.0, votesCount: $0.1) }
            )
        }
        let posts: [(content: String, poll: Poll)] = [
            ("複数選べない投票のダミー", poll("single", options: [("はい", 12), ("いいえ", 5), ("選択肢の文字が長く、何行にもわたるときの折り返しと、結果の棒の高さを確かめるための選択肢", 3)])),
            ("複数選べる投票のダミー", poll("multiple", multiple: true, expiresIn: 3_600 * 5, options: [("朝", 4), ("昼", 7), ("夜", 7), ("深夜", 0)], votersCount: 10)),
            ("締め切るまで票数を隠す投票のダミー", poll("hidden", expiresIn: 60 * 30, options: [("A", nil), ("B", nil)], votesCount: 7)),
            ("締め切った投票のダミー", poll("expired", expiresIn: -60, options: [("勝った選択肢", 30), ("負けた選択肢", 10)])),
        ]
        for post in posts {
            DummyPolls.register(post.poll)
        }
        model.debugRun { model in
            for (index, post) in posts.enumerated() {
                guard !model.isStopped else { return }
                let base = Self.dummyStatus(number: index + 1, avatar: avatar, now: model.now())
                let dummy = Status(
                    id: base.id,
                    createdAt: base.createdAt,
                    account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（投票）", avatar: avatar),
                    content: "<p>\(post.content)</p>",
                    spoilerText: "",
                    url: nil,
                    poll: post.poll
                )
                model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
                model.debugReceive(.update(dummy))
            }
        }
    }

    /// 引用のあるダミーの投稿を、新着と同じ経路で流す。引用元に画像と入れ子の引用、引用元に注意書き、承認待ち、ミュートしている人の4件。
    /// 引用元もサーバーにないため、囲みを押して開くスレッドは読み込めずに失敗する。
    private func streamDummyQuotes() {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        let quotedAccount = Account(id: "dummy-quoted", username: "quoted", acct: "quoted", displayName: "ダミー（引用元）", avatar: avatar)
        func quoted(_ id: String, content: String, spoilerText: String = "", media: [MediaAttachment] = [], quote: Quote? = nil) -> Status {
            Status(id: id, createdAt: model.now().addingTimeInterval(-3_600), account: quotedAccount, content: "<p>\(content)</p>", spoilerText: spoilerText, url: nil, mediaAttachments: media, quote: quote)
        }
        let posts: [(content: String, quote: (String) -> Quote)] = [
            ("画像と入れ子の引用のある投稿を引用したダミー", { id in
                Quote(state: "accepted", quotedStatus: quoted("\(id)-q", content: "引用元の本文。", media: DummyMedia.attachments(idPrefix: "\(id)-q"), quote: Quote(state: "accepted", quotedStatusID: "\(id)-nested")))
            }),
            ("注意書きのある投稿を引用したダミー", { id in
                Quote(state: "accepted", quotedStatus: quoted("\(id)-q", content: "注意書きの下の本文。", spoilerText: "ダミーの注意書き"))
            }),
            ("承認待ちの引用のダミー", { _ in Quote(state: "pending") }),
            ("ミュートしている人の投稿を引用したダミー", { id in
                Quote(state: "muted_account", quotedStatus: quoted("\(id)-q", content: "ミュートしている人の本文。"))
            }),
        ]
        model.debugRun { model in
            for (index, post) in posts.enumerated() {
                guard !model.isStopped else { return }
                let base = Self.dummyStatus(number: index + 1, avatar: avatar, now: model.now())
                let dummy = Status(
                    id: base.id,
                    createdAt: base.createdAt,
                    account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（引用）", avatar: avatar),
                    content: #"<p class="quote-inline">RE: <a href="https://example.com/@quoted/1">example.com/@quoted/1</a></p><p>\#(post.content)</p>"#,
                    spoilerText: "",
                    url: nil,
                    quote: post.quote(base.id)
                )
                model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
                model.debugReceive(.update(dummy))
            }
        }
    }

    /// サーバーのカードが後から届くまでの秒数。届く瞬間に合わせて、スクロールなどの操作を送れるよう、少し長めにする。
    static let dummyLinkCardDelay: Duration = .seconds(5)

    /// リンクだけのダミーの投稿を新着と同じ経路で流し、`dummyLinkCardDelay`のあとに、通信せずにカードを届ける。
    /// カードが届いたときの動きを、サーバーがカードを付けるタイミングによらず、何度でも同じ条件で確かめるため。
    /// - Parameter sensitive: 閲覧注意の投稿にする。届いたカードの画像をぼかすところを確かめる。
    private func streamDummyLinkCard(withImage: Bool, sensitive: Bool = false) {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar, now: model.now())
        guard let link = URL(string: "https://news.example/articles/\(base.id)") else { return }
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（リンクカード）", avatar: avatar),
            content: #"<p>リンクカードが届くときの確認用 <a href="\#(link.absoluteString)">news.example/articles/\#(base.id)</a></p>"#,
            spoilerText: "",
            url: nil,
            sensitive: sensitive
        )
        let card = PreviewCard(
            url: link,
            title: "ダミーの記事の見出し",
            description: "5秒後に届いたダミーのカード。",
            type: .link,
            providerName: withImage ? "News Example" : "",
            image: withImage ? CatalogFixtures.imageURL(width: 400, height: 225, color: .systemIndigo) : nil,
            width: withImage ? 400 : 0,
            height: withImage ? 225 : 0,
            blurhash: withImage ? CatalogFixtures.blurhash : nil
        )
        // 取り直しで届くのと同じく、カードの付いた同じ版の投稿として渡す。
        let carded = Status(
            id: dummy.id,
            createdAt: dummy.createdAt,
            account: dummy.account,
            content: dummy.content,
            spoilerText: "",
            url: nil,
            sensitive: sensitive,
            card: card
        )
        model.debugRun { model in
            model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
            model.debugReceive(.update(dummy))
            guard (try? await model.clock.sleep(for: Self.dummyLinkCardDelay)) != nil, !model.isStopped else { return }
            model.updateStatus(dummy.id) { $0.adoptingCard(of: carded) }
        }
    }

    /// Xの投稿へのリンクだけのダミーの投稿を流し、`dummyLinkCardDelay`のあとに、fxtwitterに頼まずに4枚の画像付きのXの投稿を届ける。
    /// リンクカードから囲みに替わるときの動きを、何度でも同じ条件で確かめるため。囲みは、チューニングで出すようにしているときだけ出る。
    private func streamDummyXPost() {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar, now: model.now())
        guard let link = URL(string: "https://x.com/dummy/status/\(base.id)") else { return }
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（Xの投稿）", avatar: avatar),
            content: #"<p>Xの投稿の囲みが届くときの確認用 <a href="\#(link.absoluteString)">x.com/dummy/status/\#(base.id)</a></p>"#,
            spoilerText: "",
            url: nil
        )
        let post = XPost(
            id: base.id,
            url: link,
            authorName: "ダミーのXのアカウント",
            authorScreenName: "dummy",
            authorAvatar: avatar,
            text: .plain("5秒後に届いたダミーのXの投稿。4枚の画像を添付している。", emojis: []),
            createdAt: model.now(),
            media: DummyMedia.attachments(idPrefix: "x-\(base.id)")
        )
        let xPosts = viewController.xPosts
        // 行を描いたときにfxtwitterへ読みに行かないよう、届けるまで読み込み中にしておく。
        xPosts?.reserve(id: post.id)
        model.debugRun { model in
            model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
            model.debugReceive(.update(dummy))
            guard (try? await model.clock.sleep(for: Self.dummyLinkCardDelay)) != nil, !model.isStopped else { return }
            xPosts?.deliver(post)
        }
    }

    /// ストリーミングで届いたのと同じ経路で、ダミーの新着を少しずつ流す。
    ///
    /// ダミーはサーバーにない投稿なので、見れば手元では既読になるが、サーバーに保存する既読位置には使わない。
    /// IDはMastodonと同じく時刻から作るため、後から届く本物の投稿はダミーより新しく並び、補完もダミー以降を読む。
    private func streamDummyArrivals(count: Int) {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        model.debugRun { model in
            for number in 1...count {
                guard !model.isStopped else { return }
                let dummy = Self.dummyStatus(number: number, avatar: avatar, now: model.now())
                model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
                model.debugReceive(.update(dummy))
                try? await model.clock.sleep(for: .milliseconds(300))
            }
        }
    }

    /// 動くカスタム絵文字の多いダミーの投稿を、新着と同じ経路で流す。動く絵文字を描く負荷を、実機でも同じ条件で比べるため。
    private func streamDummyAnimatedEmojis() {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        let statuses = (0..<DummyAnimatedEmojis.postCount).map { number in
            let base = Self.dummyStatus(number: number + 1, avatar: avatar, now: model.now())
            let content = DummyAnimatedEmojis.content(number: number)
            return Status(
                id: base.id,
                createdAt: base.createdAt,
                account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（動く絵文字）", avatar: avatar),
                content: content.html,
                spoilerText: "",
                url: nil,
                emojis: content.emojis
            )
        }
        model.debugRun { model in
            for status in statuses {
                guard !model.isStopped else { return }
                model.debugStore.debugLocalOnlyIDs.insert(status.id)
                model.debugReceive(.update(status))
            }
        }
    }

    /// ビューアを確かめるための、画像付きのダミーの投稿を、新着と同じ経路で1件流す。
    /// 画像は端末で描くため、通信せず、実際の投稿を探さずに確かめられる。
    /// - Parameter attachments: 投稿のIDを受け取り、添付ファイルを返す。
    private func streamDummyMediaStatus(content: String, attachments: (String) -> [MediaAttachment]) {
        let avatar = model.debugStore.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar, now: model.now())
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（画像）", avatar: avatar),
            content: content,
            spoilerText: "",
            url: nil,
            mediaAttachments: attachments(base.id)
        )
        model.debugRun { model in
            model.debugStore.debugLocalOnlyIDs.insert(dummy.id)
            model.debugReceive(.update(dummy))
        }
    }

    /// 動画を付けたダミー投稿を流す。動画は初回だけ端末で書き出すため、少し遅れて流れる。
    private func streamDummyVideoStatus(content: String, make: @escaping () async throws -> (String) -> [MediaAttachment]) {
        model.debugRun { [weak self] _ in
            do {
                let attachments = try await make()
                self?.streamDummyMediaStatus(content: content, attachments: attachments)
            } catch {
                SciaLog.logger(category: "media").error("dummy video failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 補完で続けて読む上限より多い数の最新の投稿を忘れてからつなぎ直し、実データで補完とギャップを起こす。
    /// 補完の基準が残るよう、先に古いページを読み足し、少なくとも1件は残す。読み足しは接続を止める前に行い、失敗しても接続は止めない。
    private func simulateMissedWhileDisconnected() {
        let targetCount = FeedTimelineModel.pageSize * Int(tuning.value(of: TuningCatalog.fillPageLimit)) + 10
        model.debugRun { model in
            do {
                while model.debugStore.statuses.count <= targetCount, !model.debugStore.reachedEnd {
                    // 再生成中は空のページが返り続けるため、増えなければやめる。
                    guard let added = try await model.debugStore.loadOlder(), !added.isEmpty else { break }
                }
            } catch {
                model.debugReport(error, during: "debug loadOlder")
                return
            }
            let forgetCount = min(targetCount, model.debugStore.statuses.count - 1)
            guard !model.isStopped, forgetCount > 0 else { return }
            model.debugForgetNewestAndReconnect(forgetCount)
        }
    }

    private static let dummyBodies = [
        "短いダミーの新着",
        "二行くらいになるダミーの新着です。挿入されたときに、読んでいる位置が動かないかを確かめるために、少し長めにしています。",
        "<p>段落が分かれたダミーの新着。</p><p>" + String(repeating: "ストリーミングで新着が流れてきても、読んでいる位置が動かないことを確かめる。", count: 4) + "</p>",
    ]

    private static func dummyStatus(number: Int, avatar: URL, now: Date) -> Status {
        // Mastodonの投稿IDと同じく、ミリ秒の時刻を16ビット左へずらし、下位に連番を入れる。
        let milliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        return Status(
            id: String(milliseconds << 16 | UInt64(number & 0xFFFF)),
            createdAt: now,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー #\(number)", avatar: avatar),
            content: dummyBodies[number % dummyBodies.count],
            spoilerText: "",
            url: nil
        )
    }
}

/// ホームに流せるダミー投稿の種類。デバッグメニューの項目と、URL（`scia-debug://dummy/<rawValue>`）の名前を兼ねる。
enum DebugDummyPost: String, CaseIterable {
    case arrivals
    case images
    case tall
    case small
    case transparent
    case video
    case longVideo = "long-video"
    case linkCard = "link-card"
    case linkCardImage = "link-card-image"
    case linkCardSensitive = "link-card-sensitive"
    case xPost = "x-post"
    case filtered
    case animatedEmojis = "animated-emojis"
    case polls
    case quotes
    case notifications

    var title: String {
        switch self {
        case .arrivals: "新着10件"
        case .images: "画像4枚"
        case .tall: "縦長の画像1枚"
        case .small: "小さい画像3枚"
        case .transparent: "透過画像1枚"
        case .video: "動画とGIF"
        case .longVideo: "音声付きの長い動画"
        case .linkCard: "後から届くリンクカード（画像なし）"
        case .linkCardImage: "後から届くリンクカード（画像あり）"
        case .linkCardSensitive: "後から届くリンクカード（閲覧注意）"
        case .xPost: "後から届くXの投稿（画像4枚）"
        case .filtered: "フィルターに一致した投稿（警告、ぼかし、隠す）"
        case .animatedEmojis: "動く絵文字の多い投稿（40件）"
        case .polls: "投票の付いた投稿（4件）"
        case .quotes: "引用のある投稿（4件）"
        case .notifications: "ステータスバーに流す通知（連続）"
        }
    }

    /// デバッグメニューで区切る分類。ステータスバーの通知は、出し続ける項目と並べるため、ダミー投稿の一覧には出さない。
    enum MenuGroup: CaseIterable {
        case timeline
        case media
        case delayed
        case content

        var title: String {
            switch self {
            case .timeline: "一覧"
            case .media: "添付ファイル"
            case .delayed: "後から届く"
            case .content: "投稿の中身"
            }
        }
    }

    var menuGroup: MenuGroup? {
        switch self {
        case .arrivals, .animatedEmojis: .timeline
        case .images, .tall, .small, .transparent, .video, .longVideo: .media
        case .linkCard, .linkCardImage, .linkCardSensitive, .xPost: .delayed
        case .filtered, .polls, .quotes: .content
        case .notifications: nil
        }
    }

    var systemImage: String {
        switch self {
        case .arrivals: "text.badge.plus"
        case .images: "photo.badge.plus"
        case .tall: "rectangle.portrait"
        case .small: "photo"
        case .transparent: "circle.dashed"
        case .video: "play.rectangle"
        case .longVideo: "speaker.wave.2"
        case .linkCard, .linkCardImage, .linkCardSensitive: "link"
        case .xPost: "quote.bubble"
        case .filtered: "line.3.horizontal.decrease.circle"
        case .animatedEmojis: "face.smiling"
        case .polls: "chart.bar.horizontal.page"
        case .quotes: "quote.opening"
        case .notifications: "bell.badge"
        }
    }
}
#endif
