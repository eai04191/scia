import os
import SciaCore
import SwiftUI
import UIKit

/// タイムライン表示。スクロール位置の制御を細かく行うため、UICollectionViewとdiffable data sourceで組む。
final class TimelineViewController: UIViewController, NavigationBarTapPassing {
    private enum Section { case main }
    typealias ItemID = TimelineEntry.ID

    private let logger = SciaLog.logger(category: "timeline")

    /// タイムラインごとに変わる文言。
    typealias Texts = TimelineTexts

    /// タイムライン全体の状態。投稿がないときの表示に使う。
    typealias ContentState = TimelineContentState

    /// 末尾の読み込みの状態。フッターに出す。
    typealias FooterState = TimelineFooterState

    /// 末尾が近づいたときに呼ぶ。古い投稿の読み込みを始める。
    var onApproachingEnd: (() -> Void)?
    /// 失敗表示の再試行ボタンで呼ぶ。
    var onRetry: (() -> Void)?
    /// 画面に表示されている投稿が変わったときに、表示中の投稿のIDを渡して呼ぶ。
    var onVisibleStatusesChange: (([Status.ID]) -> Void)?
    /// 画面に表示されている通知が変わったときに、表示中の通知のIDを渡して呼ぶ。
    var onVisibleNotificationsChange: (([MastodonNotification.ID]) -> Void)?
    /// 画面に表示されている行のうち、サーバーが仕上げ終える前に受け取ったため取り直す投稿（`StatusRefreshNeeds`）が変わったときに呼ぶ。
    /// ブーストなら、ブーストされた投稿を渡す。画面から消えたら空で呼ぶ。
    var onVisibleUnsettledStatusesChange: (([Status]) -> Void)?
    /// 投稿への操作が選ばれたときに呼ぶ。ブーストなら、ブーストした投稿を渡す。
    var onStatusAction: ((StatusAction, Status) -> Void)?
    /// 投稿のメニューの「別のアカウントで」に並べる、ログインしているほかのアカウント。なければ項目を出さない。
    var otherAccounts: OtherAccounts?
    /// 「別のアカウントで」で選んだ操作を行う。
    var onOtherAccountAction: ((OtherAccountCommand) -> Void)?
    /// フォローリクエストの通知のメニューで、承認か却下が選ばれたときに、その通知を渡して呼ぶ。
    var onFollowRequestDecision: ((FollowRequestDecision, MastodonNotification) -> Void)?
    /// 保留中の通知の行で、受け入れるか無視が選ばれたときに、そのまとまりを渡して呼ぶ。nilなら行をスワイプできない。
    var onNotificationRequestDecision: ((NotificationRequestDecision, NotificationRequest) -> Void)?
    /// 保留中の通知の行がタップされたときに呼ぶ。その人からの通知を開く。
    var onOpenNotificationRequest: ((NotificationRequest) -> Void)?
    /// 通知のメニューで、通知の削除が選ばれたときに、その通知を渡して呼ぶ。
    var onDismissNotification: ((MastodonNotification) -> Void)?
    /// まとめた通知の「ほか3人」が押されたときに呼ぶ。通知を送った人のリストを開く。
    var onOpenGroupAccounts: ((MastodonNotification) -> Void)?
    /// 右上に出す、投稿欄で書き始めるボタンが押されたときに呼ぶ。
    /// アプリ内のSafariのシートの裏に隠れているときや、設定で空の投稿欄を隠しているときに、投稿欄に触れられないため、その入口にする。
    var onFocusInlineCompose: (() -> Void)?
    private lazy var focusInlineComposeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.onFocusInlineCompose?() })
        item.accessibilityLabel = TimelineScreenTexts.focusInlineCompose
        return item
    }()
    private var showsFocusInlineCompose = false
    /// ログイン中のアカウントのID。ブーストできる投稿かの判定に使う。
    var myAccountID: String?
    /// 指によるスクロールが止まったとき、または投稿を選び終えたときに呼ぶ。
    var onInteractionSettle: (() -> Void)?
    /// ギャップがタップされたときに、どちらの端から読むかを添えて呼ぶ。
    var onGapSelect: ((String, TimelineStore.GapDirection) -> Void)?
    /// 読み込み中でないギャップが表示領域に近づいたときに、どちらの端から読むかを添えて呼ぶ。スクロールするたびに呼ぶことがある。
    var onGapApproach: ((String, TimelineStore.GapDirection) -> Void)?
    /// 投稿の行か、投稿を含む通知の行の、中の部品が受けなかった押下で呼ぶ。押した投稿（通知なら通知の投稿）と、行のウインドウ上の枠を渡す。スレッドを開く。nilなら押せない。
    var onOpenThread: ((Status, CGRect) -> Void)?
    /// 引用元の中の引用のように、IDしか分からない投稿のスレッドを開くときに、IDと、押した行のウインドウ上の枠を渡して呼ぶ。
    var onOpenStatusID: ((Status.ID, CGRect) -> Void)?
    /// スレッドの画面で押した投稿。押してもスレッドを開き直さない。
    var threadFocusID: Status.ID?
    /// スレッドを開くときに、押した行をタイムラインで見えていた位置に置くため、上の余白に足している高さ。
    private var openingInset: CGFloat = 0
    /// 画面に出るときに、この行の上端をウインドウのこの高さに置く。
    private var pendingOpening: (id: ItemID, windowY: CGFloat)?
    /// 投稿のアイコンやブーストした人の行がタップされたとき、またはメニューで選ばれたときに、そのアカウントを渡して呼ぶ。
    var onOpenProfile: ((Account) -> Void)?
    /// 人の行を左へスワイプして「外す」を押した。リストのメンバー、ミュートしたユーザー、ブロックしたユーザーの画面でだけ渡す。
    var onRemoveAccount: ((Account) -> Void)?
    /// 人の行を左へスワイプして出すボタンの名前と記号。
    var accountRemoval = (title: TimelineScreenTexts.removeAccount, symbolName: "person.badge.minus")
    /// アカウントの全体を持たない相手（メンション）のプロフィールを、IDで開く。
    var onOpenProfileID: ((String) -> Void)?
    /// 投稿の本文のリンクがタップされたときに、行き先と、本文を描いた投稿（ブーストなら元の投稿）を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination, Status) -> Void)?
    /// メニューの開く項目で、開く場所を決めてURLを開く。
    var onOpenURL: ((URL, LinkBrowser) -> Void)?
    /// リンクのメニューの「プロフィールとして開く」で、リンク先をプロフィールとして探して開く。
    var onOpenProfileURL: ((URL) -> Void)?
    /// ハッシュタグのメニューの「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    var onOpenAccountHashtag: ((String, Account) -> Void)?
    /// 投稿のメニューの「ハッシュタグ」の「すべての投稿」で、ハッシュタグのタイムラインを開く。`#`を除いた名前を渡す。
    var onOpenHashtag: ((String) -> Void)?
    /// 検索の結果のうち、投稿と人のほかの行（ハッシュタグ、「すべて見る」、失敗の行）が押されたときに呼ぶ。
    var onSearchRowSelect: ((SearchRow) -> Void)?
    /// 最近の検索の見出しの「消去」を押したときに呼ぶ。
    var onRemoveAllRecentSearches: (() -> Void)?
    /// 最近の検索の行を左へスワイプして消したときに呼ぶ。
    var onRemoveRecentSearch: ((String) -> Void)?
    /// ナビゲーションから外された。積んで開いたタイムラインが、読み込みと購読をやめるのに使う。
    var onRemovedFromParent: (() -> Void)?
    /// 画面に出始めたとき（true）と、見えなくなったとき（false）。前に出ている間だけ新着を読むタイムラインが使う。
    var onVisibilityChange: ((Bool) -> Void)?
    /// ユーザーのメニューのメンションとハンドルをコピーを組むもの。nilなら2つの項目を出さない。
    var userMenuActions: UserMenuActions?
    /// ハッシュタグのメニューのミュートを組むもの。nilなら項目を出さない。
    var hashtagMenuActions: HashtagMenuActions?
    /// この画面が表示されている間、生かしておくもの。画面を組み立てたコントローラーを、ナビゲーションから外されるまで残すのに使う。
    /// 外されたら手放す。コントローラーが画面を強く持つ持ち合いを、コントローラーの止め方によらず解くため。
    var lifetimeOwner: AnyObject?
    /// タイムラインの頭に置き、一緒にスクロールするビュー。プロフィールのヘッダーに使う。表示より前に設定する。
    /// 置くと、投稿がないときの全面の表示は出さず、読み込みの状態はフッターだけで示す。ヘッダーを覆わないようにするため。
    var headerView: UIView?
    /// 画面に出るたびに呼ぶ。開くまで読まないタイムラインが、初めて開いたときに読み始めるのに使う。
    var onAppearing: (() -> Void)?
    /// タイムラインがスクロールしたときと、安全領域やバーの高さが変わったときに呼ぶ。ヘッダーを置いた画面が、ヘッダーやバーの見た目を位置に合わせるのに使う。
    var onScroll: ((UIScrollView) -> Void)?
    /// ナビゲーションバーのボタンのない場所のタップを、タイムラインに通す。ヘッダーを置いた画面が、バーの下に入れたヘッダー画像を押せるようにする。
    var passesEmptyNavigationBarTaps = false
    /// ステータスバーの文字の色。ヘッダーを置いた画面が、ステータスバーの下に見えているものに合わせて変える。
    var statusBarStyle: UIStatusBarStyle = .default {
        didSet {
            guard statusBarStyle != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }
    #if DEBUG
    /// デバッグメニューに出す、このタイムライン用の検証の操作。表示より前に設定する。
    var debugActions: [UIMenuElement] = []
    /// デバッグメニューから起こした障害を、URLで届いたときと同じく処理する。nilなら障害の項目を出さない。表示より前に設定する。
    var onDebugURL: (@MainActor (DebugURL) -> Void)?
    #endif

    private(set) lazy var collectionView: UICollectionView = TimelineCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    /// 作り終えてから、並べ直すたびに下の余白を測る処理をつなぐ。作る途中に当てる最初のsnapshotでも並べ直すので、先につなぐと、測る処理が作り終えていない`dataSource`を読みに行き、作り直しが入れ子になって止まらない。
    private lazy var dataSource = {
        let dataSource = makeDataSource()
        // 中身の高さが変わらなくても、押した投稿より上の行の高さが変わると、押した投稿から下の高さが変わるので、並べ直すたびに測る。
        (collectionView as? TimelineCollectionView)?.onLayout = { [weak self] in
            guard let self, threadFocusID != nil else { return }
            updateBottomInset(layingOut: false)
        }
        return dataSource
    }()
    private var entries: [ItemID: TimelineEntry] = [:] {
        didSet { emojiURLIndex = nil }
    }
    /// 絵文字の画像のURLから、それを描く行を引く。画像が届くたびに全部の行の絵文字を集め直さないため、行か引用元の変更が変わったときだけ作り直す。
    /// 絵文字ピッカーを流す間は、ほぼ毎フレーム画像が届き、そのたびに集め直すと、行の数に比例してメインスレッドを使っていた。
    private var emojiURLIndex: [URL: [ItemID]]?
    /// メニューを開いている間に届いたアイコンを、メニューを組み直さずに差し替える。
    let contextMenuIcons = ContextMenuIconSwapper()
    /// 行を触れた位置。行のタップの処理は押した位置を受け取らないため、タップでメニューを出す位置にする。
    let touchRecorder = TouchLocationRecorder()
    /// 行の長押しにメニュー以外を選んだときに、長押しを受ける。
    var rowLongPress: ObjectLongPress?
    /// 組んでいるメニューで、アイコンを読んでから差し替える人。メニューを組み終えたら、まとめて読み始める。
    var pendingMenuIcons: [PendingMenuIcon] = []
    /// 前回`setEntries`で並べた配列。次に渡された`keepingRowContentsOf`と同じ配列かを、中身を比べずに確かめるために持つ。
    private var appliedEntries: [TimelineEntry] = []
    /// 隣の行とアイコン同士を線でつなぐ行。並びが変わるたびに決め直す。
    private var replyConnections: [ItemID: ReplyConnection] = [:]
    /// すぐ上の行が返信先なら、返信のラベルを出さない。スレッドのように古い順に並べるタイムラインで、線で返信先が分かるため。
    /// ただし、スレッドで押した投稿（`threadFocusID`）にはラベルを残す。新しい順に並べるタイムラインでは、返信先は下の行になるため使わない。
    var hidesReplyLabelBelowParent = false
    private var loadingGapIDs: Set<String> = []
    /// 直近の読み込みに失敗したギャップと、その理由。行の中で読めなかったことを知らせる。
    private var gapFailures: [String: ErrorPresentation] = [:]
    private(set) var isShowingMenu = false
    private var swipeCloseTicker: FrameTicker?
    /// スワイプのボタンを閉じる途中に届いた並びの更新。閉じ終えたときに反映する。
    private var heldEntries: HeldEntries?
    /// 画面に出ていない間（ほかのタブ、上に重ねた画面の下）に、絵文字やXの投稿が届いて求められた描き直し。画面に出るときに描き直す。
    private var hiddenReconfigureIDs: Set<ItemID> = []
    private var contentSizeObserver: (any NSObjectProtocol)?
    private var windowActivationObservers: [any NSObjectProtocol] = []
    /// 端末の文字の大きさが変わったときに、組み直す前に覚えた読んでいる位置。
    private var contentSizeAnchor: ScrollAnchor?
    /// 表示中のギャップのID。スクロールのたびに全要素を調べないよう、別に持つ。
    private var gapIDs: [String] = []
    /// 指で最後に動かした向き。ギャップをどちらの端から読むかに使う（`TimelineLoadTrigger.approachingGaps`）。
    private var lastScrollDirection: TimelineLoadTrigger.ScrollDirection?
    private(set) var contentState = ContentState.loaded
    private(set) var footerState = FooterState.idle
    /// 光の下に敷く区切り線の左端。線を決めるのはセルを作る前なので、作ったセルに渡すために取っておく。
    private var reactionGlowSeparatorLeadings: [ItemID: CGFloat] = [:]
    private(set) var unreadCount = 0
    /// スクロール位置を補正している間は、途中の表示を既読として報告しない。
    private var isRestoringAnchor = false
    /// 最上部や投稿へスプリングで動かしている間、毎フレーム経過時間を渡すもの。
    private var springScrollTicker: FrameTicker?
    /// 最上部や投稿へスプリングで動かすときに、毎フレームの経過時間を送る元。テストでは手で送る元に替える。
    var frameSource: any FrameSource = DisplayLinkFrameSource.shared
    /// スプリングで動かしている間の、スプリングの位置の進め方と今の速さ。
    private var springScroll: SpringScroll?
    /// スプリングで動かしている行き先。
    private var springScrollDestination = SpringScrollDestination.top
    /// スプリングで動かしている間だけ有効にし、指が触れた時点で止める。触れたタッチは、指が離れるまで中身に渡さない。
    /// UIKitのスクロールと同じく、動いているタイムラインに触れて止めたつもりで、指の下の画像やリンクが開かないようにするため。
    private(set) lazy var springScrollInterruption = makeSpringScrollInterruption()
    /// 指で動かしているスクロールの始まり。止まったら違和感レポート用に記録する。
    private var scrollStart: (offset: CGFloat, time: CFTimeInterval)?
    private let scrollHitches = ScrollHitchMonitor()
    /// 投稿のメニューの、システムの翻訳で出す翻訳シート。
    let translation = SystemTranslation()
    /// 「テキストを選択」で選べる状態にしている本文。タイムラインの行をタップしたときと、画面を離れたときにやめる。
    private weak var textSelectionBody: PostBodyView?
    /// 投稿のメニューで「テキストを選択」を選んだ本文と、その投稿。メニューが閉じ終えてから選び始める。閉じる途中に選ぶと、編集メニューが出ないため。
    private var pendingTextSelection: (body: PostBodyView, statusID: Status.ID)?
    /// まとめて行う操作のために選んでいる行。選んでいないときはnil。決まりはdocs/batch-actions.mdにある。
    var postSelection: OrderedSelection<ItemID>?
    /// 選び始める前のナビゲーションバーの中身。選び終えたら戻す。
    var navigationItemBeforePostSelection: PostSelectionNavigationItems?
    /// 投稿を選び始めたときと、選び終えたとき。投稿欄のカプセルを隠したり戻したりする。
    var onPostSelectionChange: ((Bool) -> Void)?
    /// 選んだ順の投稿を、まとめてブーストする。
    var onBatchReblog: (([Status]) -> Void)?
    /// 選んだ順の投稿を、まとめて共有する。
    var onBatchShare: (([Status]) -> Void)?
    private lazy var newArrivalsButton = makeNewArrivalsButton()
    /// 新着ボタンを出す向きか。消える動きの途中は、`isHidden`がまだ偽でも偽になる。
    private(set) var newArrivalsButtonShown = false
    /// 新着ボタンに「↑」を出しているか。スクロールのたびに比べるため、ボタンの設定を読まずに済むよう覚えておく。
    private(set) var newArrivalsButtonShowsArrow = true
    /// 新着ボタンの出し入れを始めた回数。途中で向きを変えると、前の動きの完了がその場で呼ばれるため、最後の動きの完了でだけ隠す。
    private var newArrivalsButtonGeneration = 0
    /// 使う人の操作（新着ボタン、タブの選び直し、ステータスバーのタップ）で最上部へ戻している。戻る間は新着ボタンを隠す。
    /// 新着に追従して戻る間は、出ているボタンをそのまま出しておく。
    private var isScrollingToNewestByUser = false
    /// タイムラインの最上部から引っぱって、浮かべた新着のボタンを下げている量。
    private var pulledDistance: CGFloat = 0
    /// アプリ全体のアプリ内通知。お気に入りやブーストの失敗、リンクのコピーを出す。セッションが入れる。
    var notices: NoticeCenter?
    /// 添付ファイルのビューアで、共有や保存のために落とす処理。ビューアを閉じても続けるため、セッションで持つ。
    var mediaTransfers: MediaTransferCenter?
    private var timeRefreshTask: Task<Void, Never>?
    /// 画面の前後の投稿の本文を、先に作って並べておく。
    private let bodyTextPreparer = BodyTextPreparer()
    /// 本文を先に作った、画面に出ている行の範囲。同じ範囲では頼み直さない。
    var preparedBodyRange: ClosedRange<Int>?
    /// 最後に読めた、本文のラベルの値と幅。
    private var bodyTextGeometry: BodyTextPreparer.Geometry?
    /// 今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    /// 時間をおく処理の時計。テストでは手で進める時計に差し替える。
    var clock: any Clock<Duration> = AppDependencies.clock
    private let texts: Texts
    /// タイムラインを一番上から引っぱって離したときに、最新の状態を読む。読み終えるまで更新コントロールを出し続ける。
    /// どのタイムラインでも同じ操作で読み直せるよう、タイムラインを持つ側に必ず決めさせる。
    private let refresh: @MainActor () async -> Void
    private let refreshControl = UIRefreshControl()
    private var refreshTask: Task<Void, Never>?
    let tuning: TuningStore
    let emojiImages: EmojiImageStore<UIImage>
    let mediaImages: MediaImageStore<UIImage>
    let avatarImages: AvatarImageStore<UIImage>
    let network: NetworkConditionsMonitor
    let settings: AppSettings
    /// 区切り線の引き方と、描き直しの要る設定の変化。予約投稿のタイムラインと同じ決まりを使う。
    private let listStyle: PostListStyle
    private let crashGuard: PostCrashGuard
    /// スクロールが止まったときに見えている画像を、ビューアで開く元の画像で先読みする。セッションが入れる。nilなら先読みしない。
    var mediaPrefetcher: MediaPrefetcher?
    /// 添付ファイルをぼかすか。閲覧注意のぼかしを外した投稿と、メニューから隠した投稿を覚える。セッションがほかの画面とそろえる。
    var mediaCovers = MediaCovers() {
        didSet {
            if mediaCovers != oldValue { onUpdateMediaCovers?() }
        }
    }
    /// `mediaCovers`が変わったときに呼ぶ。行の外でぼかしを描く部品（プロフィールの固定された投稿のカード）が描き直すのに使う。
    var onUpdateMediaCovers: (() -> Void)?
    /// 設定、チューニング、回線の状態が変わって、行を描き直したときに呼ぶ。行の外で添付ファイルを描く部品（プロフィールの固定された投稿のカード）が描き直すのに使う。
    var onApplySettingsChange: (() -> Void)?
    /// この画面で開いたり隠したりしたときに、変えたあとの状態と、変えた投稿を渡して呼ぶ。
    var onChangeMediaCovers: ((MediaCovers, Status) -> Void)?
    /// fxtwitterから読んだXの投稿。セッションの中で1つを共有する。
    var xPosts: XPostStore?
    /// 投稿の本文の自動翻訳。使えないOSではnil。
    var translations: StatusTranslationStore?
    /// このタイムラインで当てるサーバーのフィルターと、警告で折りたたんだ投稿のうち開いたもの。タイムラインを持つ側が、タイムラインの場所に合わせて入れる。
    var filterWarnings = FilterWarnings()
    /// ブロックかミュートしている人の引用元のうち、押して開いたもの。
    var quoteReveals = QuoteReveals()
    /// 引用元の、受け取ったあとの変化。セッションがほかの画面とそろえる。
    var quoteSourceChanges = QuoteSourceChanges() {
        didSet { emojiURLIndex = nil }
    }
    /// 投票する前に選んでいる選択肢と、結果を見ると選んだ投票、送っている途中の投票。
    var pollChoices = PollChoices()
    /// 投票の「投票」が押されたときに、選んだ選択肢と、押した投稿（ブーストならブーストした投稿）を渡して呼ぶ。
    /// 送り終えたら、呼ばれた側が`finishVoting(_:succeeded:)`を呼ぶ。
    var onVote: ((Set<Int>, Status) -> Void)?
    /// 投票の「更新」が押されたときに、押した投稿を渡して呼ぶ。読み終えたら、呼ばれた側が`finishRefreshingPoll(_:)`を呼ぶ。
    var onRefreshPoll: ((Status) -> Void)?
    /// サーバーの、Mastodonにない機能の有無。読めたら、セッションが入れる。
    /// 絵文字のリアクションに対応していなければ、投稿にリアクションがあっても出さない（docs/emoji-reaction.md）。
    var capabilities = ServerCapabilities.mastodon {
        didSet {
            guard capabilities != oldValue, isViewLoaded else { return }
            // 引用の決まりは、アクションバーに並べた「引用」を押せるかを変えるので、出しているすべてを描き直す。
            guard capabilities.quotes == oldValue.quotes else { return reconfigure(Set(displayedItemIDs)) }
            guard capabilities.supportsEmojiReactions != oldValue.supportsEmojiReactions else { return }
            reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.emojiReactions.isEmpty == false }))
        }
    }
    /// ログインしているサーバーのカスタム絵文字を、ショートコードで引くもの。リアクションに画像のURLを付けないサーバーで、セッションが入れる。
    var localReactionEmojis: [String: CustomEmoji] = [:] {
        didSet {
            guard localReactionEmojis != oldValue else { return }
            emojiURLIndex = nil
            guard isViewLoaded else { return }
            reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.emojiReactions.contains { $0.emoji.url == nil && $0.emoji.isCustom } == true }))
        }
    }
    /// リアクションのボタンが押されたときに、押した投稿（ブーストならブーストした投稿）と絵文字を渡して呼ぶ。
    var onToggleEmojiReaction: ((Status, ReactionEmoji) -> Void)?
    /// リアクションの列の「＋」が押されたときに、押した投稿を渡して呼ぶ。nilなら「＋」を出さない。
    var onAddEmojiReaction: ((Status) -> Void)?
    /// リアクションのボタンのメニューの「リアクションした人」で、その投稿にその絵文字でリアクションした人のリストを開く。
    var onOpenEmojiReactionedBy: ((Status, ReactionEmoji) -> Void)?
    /// 注意書きのある投稿の本文を開いているか。サーバーの設定が読めたら、セッションが既定を入れる。
    var spoilerExpansion = SpoilerExpansion() {
        didSet {
            guard spoilerExpansion.expandsByDefault != oldValue.expandsByDefault, isViewLoaded else { return }
            reconfigure(Set(displayedItemIDs.filter { status(for: $0)?.displayed.spoilerText.isEmpty == false }))
        }
    }

    /// 「続きを読む」で広げた本文。決まりはdocs/long-post.mdにある。セッションが持ち、開いているタイムラインにそろえて配る。
    var longBodyExpansion = LongBodyExpansion()
    /// 「続きを読む」で本文を広げたときに、広げたあとの状態と広げたものを渡して呼ぶ。セッションが、ほかのタイムラインにもそろえる。
    var onChangeLongBodyExpansion: ((LongBodyExpansion, LongBodyExpansion.Key) -> Void)?

    /// 「投稿の見た目」と「通知の見た目」のプレビューに置くタイムライン。見本の投稿と通知を並べて見せるだけで、リンクを開くほかは、押す、長押し、スワイプ、引っぱって読み直す操作と、末尾の表示を出さない。
    /// 設定の値を変えたときは、行の部品を新しい位置まで動かして見せる。決まりはdocs/appearance.mdの「プレビュー」にある。画面を読み込む前に決める。
    var isAppearancePreview = false

    init(
        texts: Texts = .home,
        settings: AppSettings,
        refresh: @escaping @MainActor () async -> Void,
        tuning: TuningStore = AppDependencies.tuning,
        emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages,
        mediaImages: MediaImageStore<UIImage> = AppDependencies.mediaImages,
        avatarImages: AvatarImageStore<UIImage> = AppDependencies.avatarImages,
        network: NetworkConditionsMonitor = AppDependencies.network,
        crashGuard: PostCrashGuard = AppDependencies.postCrashGuard
    ) {
        self.crashGuard = crashGuard
        self.texts = texts
        self.refresh = refresh
        self.tuning = tuning
        self.emojiImages = emojiImages
        self.mediaImages = mediaImages
        self.avatarImages = avatarImages
        self.network = network
        self.settings = settings
        listStyle = PostListStyle(settings: settings, tuning: tuning, network: network)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 画面を読み込んだときに並べた右上のボタン。投稿欄で書き始めるボタンは、出すときにこの先頭に足す。
    private var baseBarItems: [UIBarButtonItem] = []
    /// 画面を組み立てる側が足す右上のボタン。投稿欄で書き始めるボタンの左に並ぶ。画面を読み込んだあとに変えても並べ直す。
    var screenBarItems: [UIBarButtonItem] = [] {
        didSet {
            if isViewLoaded { applyBarItems() }
        }
    }

    /// 右上に投稿欄で書き始めるボタンを出すかを決める。画面を読み込む前は値だけ覚える。
    func setShowsFocusInlineCompose(_ shows: Bool) {
        guard showsFocusInlineCompose != shows else { return }
        showsFocusInlineCompose = shows
        if isViewLoaded { applyBarItems() }
    }

    /// `rightBarButtonItems`は右から並ぶため、先頭に足したボタンがいちばん右に来る。
    /// デバッグメニューのボタンを、`DeveloperMode`に合わせて出したり消したりする。読み込み済みの画面にも、切り替えた時点で反映する。
    private func observeDeveloperMode() {
        withObservationTracking {
            baseBarItems = AppDependencies.developerMode.isEnabled ? [makeDebugMenuButton(extraSections: debugOnlyMenuSections())] : []
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.observeDeveloperMode()
            }
        }
        applyBarItems()
    }

    private func debugOnlyMenuSections() -> [UIMenuElement] {
        #if DEBUG
        makeDebugOnlyMenuSections(screenActions: debugActions, faults: onDebugURL.map { DebugFaultMenu.make(handle: $0) }, handle: onDebugURL)
        #else
        []
        #endif
    }

    func applyBarItems() {
        // 投稿を選んでいる間は、右上のボタンを出さない。選び終えたら並べ直す。
        guard !isSelectingPosts else { return }
        navigationItem.rightBarButtonItems = (showsFocusInlineCompose && onFocusInlineCompose != nil ? [focusInlineComposeItem] : []) + screenBarItems + baseBarItems
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 画面を組み立てる側が先に入れたサブタイトル（人のリストのハンドル）を消さないよう、文言にあるときだけ入れる。
        if let subtitle = texts.subtitle {
            navigationItem.subtitle = subtitle
        }
        if !texts.title.isEmpty {
            title = texts.title
        }
        observeDeveloperMode()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.hidesTopEdgeEffectOnMac()
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.addGestureRecognizer(springScrollInterruption)
        if isAppearancePreview {
            // 枠の中の見本の位置を、置いた側が決める。ナビゲーションバーの下などの安全領域で、見本を下へずらさない。
            collectionView.contentInsetAdjustmentBehavior = .never
            previewChoices = settings.appearance
        } else {
            installRowObjectActions()
        }
        // タブバーの上の投稿欄で書いている間も、読み進めるだけならキーボードを閉じない。キーボードまで引き下ろしたら閉じる。
        collectionView.keyboardDismissMode = .interactive
        if !isAppearancePreview {
            refreshControl.addAction(UIAction { [weak self] _ in self?.beginRefresh() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
        }
        // タイムラインが画面の高さに満たないときも、引っぱって読み直せるようにする。
        collectionView.alwaysBounceVertical = true
        view.addSubview(collectionView)
        // 新着のボタンは、このタイムラインの部品として画面と一緒に流れる。一番上の投稿の名前や本文を隠さないよう、時刻のある右上に置く。
        // チップの列はウインドウに重ね、このボタンが出ていてもずらさずに上に重ねる。
        view.addSubview(newArrivalsButton)
        NSLayoutConstraint.activate([
            newArrivalsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            newArrivalsButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        AppDependencies.stateDumps.register(texts.dumpName, owner: self) { $0.stateDump() }
        emojiImages.addListener(owner: self) { [weak self] urls in
            FrameWork.measure("TimelineViewController.emojiImagesDidLoad") { self?.emojiImagesDidLoad(urls) }
        }
        avatarImages.addListener(owner: self) { [weak self] key in self?.avatarImageDidLoad(key) }
        observeTuning()
        // 行の文字は、組むときのアプリの文字の大きさで決めるため、端末の文字の大きさが変わったら組み直す。
        // アプリへの通知は、タイムラインに特性が伝わる前に届くので、そこで読んでいる位置を覚える。タイムラインに特性が伝わると、UIKitが画面の外の行の高さを
        // 見積もりに戻して測り直し、読んでいる位置がずれるため、伝わったあとに組み直して、覚えた位置へ戻す。
        contentSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.contentSizeAnchor == nil, self.viewIfLoaded?.window != nil else { return }
                self.contentSizeAnchor = self.currentAnchor()
                // 戻し終えるまで、測り直しで一時的に見えた投稿を表示中として報告しない。報告すると、読んでいない投稿まで既読になり、戻らない。
                self.isRestoringAnchor = true
            }
        }
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UICollectionView, _) in
            self?.contentSizeDidChange()
        }
        translation.install(in: self)
        observeWindowActivation()
    }

    isolated deinit {
        contentSizeObserver.map(NotificationCenter.default.removeObserver)
        windowActivationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// タイムラインを置いたウィンドウが前面を離れたり戻ったりしたら、覆われたときと同じく、見たと報告するかを切り替える。
    /// Macでは、ほかのアプリが手前にあってもシーンは`foregroundActive`のままなので、Sciaが手前のアプリかの知らせも受ける。
    private func observeWindowActivation() {
        // シーンの`willDeactivate`は状態が変わる前に届くため、シーンの知らせでは、知らせの種類から前面かを決める。
        let sceneChanges: [(Notification.Name, Bool)] = [(UIScene.willDeactivateNotification, false), (UIScene.didActivateNotification, true)]
        let sceneObservers = sceneChanges.map { name, isActive in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let scene = notification.object as? UIScene
                MainActor.assumeIsolated {
                    guard let self, let scene, scene === self.viewIfLoaded?.window?.windowScene else { return }
                    self.updateWindowInactive(isSceneActive: isActive)
                }
            }
        }
        let applicationObservers = [MacApplication.didResignActiveNotification, MacApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowInactive() }
            }
        }
        windowActivationObservers = sceneObservers + applicationObservers
    }

    /// シーンが前面で動いていて、Macでは加えてSciaが手前のアプリなら、ウィンドウが前面にある。
    /// - Parameter isSceneActive: シーンが前面で動いているか。nilなら、今の状態を読む。
    private func updateWindowInactive(isSceneActive: Bool? = nil) {
        guard let windowScene = viewIfLoaded?.window?.windowScene else { return }
        let isSceneActive = isSceneActive ?? (windowScene.activationState == .foregroundActive)
        setWindowInactive(!isSceneActive || MacApplication.isActive == false)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    /// 安全領域やナビゲーションバーの高さが変わったら、チップの列を置き直す。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        noticeOverlay?.update()
        onScroll?(collectionView)
    }

    /// 他のタブにいる間に表示が変わっても既読にしないため、画面に出たときに改めて報告する。
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // 前面にないウィンドウで開いた画面は、前面に戻る知らせが届くまで報告しない。
        updateWindowInactive()
        onAppearing?()
        onVisibilityChange?(true)
        applyPendingOpening()
        listStyle.applyHeldChange()
        applyHiddenReconfigures()
    }

    /// 読んでいる途中にもう一度引っぱっても、読み込みは重ねず、今の読み込みが終わったところで閉じる。
    private func beginRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task(.action) { [weak self] in
            guard let self else { return }
            await refresh()
            refreshTask = nil
            refreshControl.endRefreshing()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportVisibleItems()
        startRefreshingTimes()
        prepareActionBarIfNeeded()
        if translations != nil {
            requestTranslationsAroundVisibleRows()
        }
    }

    /// ハードウェアキーボードのnで、投稿欄で書き始める。入力欄に書いている間は、文字の入力が先に受けるため効かない。
    override var keyCommands: [UIKeyCommand]? {
        guard onFocusInlineCompose != nil else { return super.keyCommands }
        let focus = UIKeyCommand(title: TimelineScreenTexts.focusInlineCompose, action: #selector(focusInlineComposeFromKeyboard), input: "n")
        return (super.keyCommands ?? []) + [focus]
    }

    @objc private func focusInlineComposeFromKeyboard() {
        onFocusInlineCompose?()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            onRemovedFromParent?()
            lifetimeOwner = nil
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endTextSelection()
        endPostSelection()
        timeRefreshTask?.cancel()
        timeRefreshTask = nil
        onVisibleUnsettledStatusesChange?([])
        onVisibilityChange?(false)
    }

    /// 相対表記の時刻を、表示中の行だけ1秒ごとに書き直す。行の高さは変わらないため、並びは描き直さない。
    private func startRefreshingTimes() {
        timeRefreshTask?.cancel()
        let clock = clock
        timeRefreshTask = Task(.withoutRequests) { [weak self] in
            while (try? await clock.sleep(for: .seconds(1), tolerance: .milliseconds(200))) != nil {
                guard let self else { return }
                refreshVisibleTimes()
            }
        }
    }

    private func refreshVisibleTimes() {
        let now = now()
        refreshVisiblePolls(now: now)
        guard settings.appearance.statusTimeStyle == .relative else { return }
        for cell in collectionView.visibleCells {
            (cell.contentView as? PostContentView)?.refreshTime(now: now)
        }
    }

    /// 表示中の投票のうち、残り時間や締め切りで見え方が変わったものだけを描き直す。表示したまま締め切りを迎えた投票を、投票できる形のまま残さないため。
    /// 投票の行の高さは形や残り時間で変わらないため、描き直しても並びは動かない。
    private func refreshVisiblePolls(now: Date) {
        var stale: Set<ItemID> = []
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let poll = status(for: id)?.displayed.poll,
                  let drawn = (collectionView.cellForItem(at: indexPath)?.contentView as? PostContentView)?.pollDisplay,
                  PollDisplay(poll: poll, choices: pollChoices, now: now) != drawn else { continue }
            stale.insert(id)
        }
        reconfigure(stale)
    }

    /// チューニングの値、回線の状態、設定が変わったら、表示中の投稿を描き直す。見えていない間と、設定の画面が手前にある間は、`listStyle`が溜める。
    private func observeTuning() {
        listStyle.isShown = { [weak self] in self?.viewIfLoaded?.window != nil }
        listStyle.onRedrawNeeded = { [weak self] in self?.applySettingsChange() }
        listStyle.observeRedrawNeeds()
    }

    /// 設定の画面が手前にある間は、設定やチューニングが変わっても描き直さずに溜める。
    var holdsSettingsChanges: Bool {
        get { listStyle.holdsChanges }
        set { listStyle.holdsChanges = newValue }
    }
    /// 見えていない間か、`holdsSettingsChanges`の間に、設定やチューニングが変わった。
    var hasHeldSettingsChange: Bool { listStyle.hasHeldChange }

    private func applySettingsChange() {
        emojiURLIndex = nil
        if isAppearancePreview {
            applyPreviewSettingsChange()
            return
        }
        reconfigure(Set(dataSource.snapshot().itemIdentifiers))
        // 区切り線はリストのレイアウトが引くので、描き直しでは変わらない。引き直させる。
        collectionView.collectionViewLayout.invalidateLayout()
        onApplySettingsChange?()
    }

    /// プレビューの見本の行の中身。見本に並べる投稿と通知のほかはnil。
    private func previewContentConfiguration(for entry: TimelineEntry, id: ItemID, base: UIListContentConfiguration) -> (any UIContentConfiguration)? {
        switch entry {
        case .status(let status): contentConfiguration(for: status, itemID: id, base: base)
        case .notification(let notification): contentConfiguration(for: notification, itemID: id, base: base)
        case .pinned, .gap, .unreadable, .account, .notificationRequest, .search: nil
        }
    }

    /// 前に描き直したときの、数値以外の見た目の設定。プレビューで、部品を動かすかを決める。
    private var previewChoices: AppearanceChoices?

    /// プレビューで、余白や大きさを変えたときは、行の中の部品と下の行を新しい位置まで動かして見せる。どこがどう変わったかを目で追えるようにするため。
    /// 文字の大きさは補間できないので、文字は新しい大きさに切り替わり、位置だけが動く。
    /// 数値以外の設定（出すかどうかや表記）を変えたときは動かさない。出していなかった部品は前の位置を持たないため、動かすと、位置0から飛んでくるように見える。
    /// 差分を当てる描き直し（`dataSource.apply`）は、中で動きを止めて並べ直しまで済ませるので、見えている行は差分を通さずにセルの中身を差し替え、
    /// 行の大きさと中の部品の並べ直しを動きの中で行う。見えていない行は、動かさずに描き直す。
    private func applyPreviewSettingsChange() {
        let choices = settings.appearance
        let animates = previewChoices == choices && !UIAccessibility.isReduceMotionEnabled
        previewChoices = choices
        var visibleIDs: Set<ItemID> = []
        let apply = {
            for case let cell as TimelineCell in self.collectionView.visibleCells {
                guard let indexPath = self.collectionView.indexPath(for: cell), let id = self.dataSource.itemIdentifier(for: indexPath), let entry = self.entries[id] else { continue }
                // セルの`contentConfiguration`に入れ直すと、セルが動きの外で中を並べ直すため、投稿と通知の行は、行のビューに中身を直接渡す。
                // 通知の組み方が変わって行のビューの種類が変わるときは、行のビューが受け付けないので、セルに入れ直す。
                cell.discardShrinkSnapshot()
                if let content = cell.contentView as? any UIContentView,
                   let configuration = self.previewContentConfiguration(for: entry, id: id, base: cell.defaultContentConfiguration()),
                   type(of: content.configuration) == type(of: configuration) {
                    content.configuration = configuration
                    cell.updateSizingParts(from: configuration)
                } else {
                    self.configure(cell, for: entry, id: id)
                    cell.updateSizingParts(from: cell.contentConfiguration)
                }
                // リストは行の高さを測るとき、動きの外でセルの中を並べ直すので、その前に、動きの中で中の部品を新しい位置へ動かしておく。
                cell.layoutIfNeeded()
                visibleIDs.insert(id)
            }
            // 行の高さと区切り線はリストのレイアウトが決めるので、測り直させる。
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
        }
        if animates {
            UIView.animateSpring(duration: Self.smoothDuration, in: collectionView, changes: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
        let hiddenIDs = Set(dataSource.snapshot().itemIdentifiers).subtracting(visibleIDs)
        guard !hiddenIDs.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(hiddenIDs))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 絵文字の画像が届いたら、その絵文字を使う投稿だけを描き直す。読んでいる位置は保つ。
    /// 文字が横へずれたり次の行へ移ったりする動きは、ラベルが付ける（`EmojiArrivalTransition`）。
    /// 折り返しが変わって見えている行の高さが変わるときは、下の行ごと動かしてつなぐ（`reconfigureShiftingRowsBelow`）。
    /// 画面に出ていれば`redraw`で描き直し、出ていなければ画面に出るまで溜める。
    /// 絵文字とXの投稿のストアは、読めなかったものを読み直してよくなったときにも知らせ、描き直した行が求めると読みに行く。
    /// 隠れたまま描き直すと、見えていない行の分まで読みに行くため（docs/network.md）。
    func reconfigureWhenShown(_ ids: Set<ItemID>, redraw: (Set<ItemID>) -> Void) {
        guard !ids.isEmpty else { return }
        guard viewIfLoaded?.window != nil else {
            hiddenReconfigureIDs.formUnion(ids)
            return
        }
        redraw(ids)
    }

    private func applyHiddenReconfigures() {
        let ids = hiddenReconfigureIDs.intersection(dataSource.snapshot().itemIdentifiers)
        hiddenReconfigureIDs.removeAll()
        reconfigure(ids)
    }

    private func emojiImagesDidLoad(_ urls: Set<URL>) {
        let index = emojiURLIndex ?? makeEmojiURLIndex()
        emojiURLIndex = index
        // 索引は`entries`から作るので、並びにない行も入る。並びにある行だけを描き直す。
        let ids = Set(urls.flatMap { index[$0] ?? [] }).filter { dataSource.indexPath(for: $0) != nil }
        reconfigureWhenShown(ids) { reconfigureShiftingRowsBelow($0, duration: tuning.value(of: TuningCatalog.customEmojiArrivalDuration)) }
    }

    private func makeEmojiURLIndex() -> [URL: [ItemID]] {
        var index: [URL: [ItemID]] = [:]
        let accountEmojis: (Account) -> [CustomEmoji] = { [settings] in settings.userDisplays.display(of: $0, in: settings).emojis }
        for (id, entry) in entries {
            let urls: Set<URL> = switch entry {
            case .status(let status), .pinned(let status): Self.emojiURLs(of: status, quoteSources: quoteSourceChanges, localReactionEmojis: localReactionEmojis, accountEmojis: accountEmojis)
            case .notification(let notification): Self.emojiURLs(of: notification, quoteSources: quoteSourceChanges, localReactionEmojis: localReactionEmojis, accountEmojis: accountEmojis)
            case .account(let account): Self.imageURLs(of: accountEmojis(account))
            case .notificationRequest(let request): Self.imageURLs(of: accountEmojis(request.account))
            case .gap, .unreadable, .search: []
            }
            for url in urls {
                index[url, default: []].append(id)
            }
        }
        return index
    }

    /// 行の中身を、同じセルのまま動かさずに描き直し、高さが変わって位置がずれた見えている行と区切り線を、元の位置から新しい位置へ動かしてつなぐ。
    /// 上端が表示領域の上端より上にある行の高さが、使う人の操作によらず変わるときは、下の行は動かず、動かすものがない（`upwardResizingRow`、docs/vision.mdの「タイムラインの動き」）。
    /// 押し下げられて表示領域の外へ出る行は、描き直す前に取っておいた像を動かして外へ送る。
    ///
    /// 動きは、層の位置に足し合わせる形（additive）で付ける。描き直しを続けて重ねても、前の動きの途中の位置から次の動きがつながり、
    /// スクロールでタイムラインが行の位置を置き直しても、動きは外れない。差分を動きつきで当てる描き直しと違い、タイムラインがセルを入れ替えないので、
    /// セルの中で続いている動き（絵文字が入る文字の動きなど）も止まらない。
    /// 区切り線は、行のセルとは別のビューとしてタイムラインに並ぶため、セルと一緒に動かす。動かさないと、伸びた行の下の線だけが1コマで下がる。
    /// - Parameter anchorID: 画面上の位置を保つ行。なければ、表示領域の上端にかかっている行を基準にする。
    /// - Parameter concealsShrink: 縮んだ行の、なくなった部品の場所に、描き直す前の像を見せて、まわりが詰めてくるのに合わせて縮める。縮む中身を自分で動かして消す描き直し（訳文、リアクション）では見せない。
    /// - Parameter shiftLimit: 描き直した行が伸び縮みする長さの上限。分かっていれば、上下のどちらかの端からタイムラインの外へ出うる行の像だけを取る。像を取るのは重く、押した直後のコマが遅れて、動きの始まりが飛んで見えるため。nilなら、描き直す行より下のすべての行の像を取る。
    func reconfigureShiftingRowsBelow(_ ids: Set<ItemID>, keeping anchorID: ItemID? = nil, duration: TimeInterval, shiftLimit: CGFloat? = nil, concealsShrink: Bool = true) {
        guard !ids.isEmpty else { return }
        guard animatesRowShift(duration: duration) else {
            reconfigure(ids, keeping: anchorID)
            return
        }
        let before = visibleRows(snapshottingBelow: ids, within: shiftLimit)
        let separatorsBefore = visibleSeparators()
        // 縮むかは描き直すまで分からないので、描き直す行の像は先に取っておく。
        let resizedBefore = ids.compactMap { id in
            cell(for: id).map { (id: id, height: $0.bounds.height, contentBottom: contentBottom(of: $0), maxY: $0.convert($0.bounds, to: nil).maxY, parts: rowParts(of: $0), snapshot: concealsShrink ? $0.snapshotView(afterScreenUpdates: false) : nil) }
        }
        isShiftingRows = true
        reconfigure(ids, keeping: anchorID)
        collectionView.layoutIfNeeded()
        isShiftingRows = false
        for row in resizedBefore {
            guard let cell = cell(for: row.id) else { continue }
            let growth = cell.bounds.height - row.height
            // 下端を保って上へ伸び縮みした行（`upwardResizingRow`）は、下の行が動かないので、行の切り抜きは要らない。上から切り抜くと、見えていた下の部分が一度隠れる。
            let keepsBottom = abs(cell.convert(cell.bounds, to: nil).maxY - row.maxY) <= 0.5
            // 下へ伸びた行は、前の中身の下の端から切り抜きを広げる。前の高さからにすると、前は余白だった部分に、新しい中身が最初のコマで見える。
            if !keepsBottom, growth > 0.5 {
                revealGrowth(of: cell, from: row.contentBottom, duration: duration)
            }
            shiftParts(of: cell, from: row.parts, growth: growth, keepsBottom: keepsBottom, snapshot: row.snapshot, oldHeight: row.height, duration: duration)
        }
        let after = visibleRows(snapshottingBelow: [])
        // 動かす行と区切り線は、動かない行より手前に描く。伸びた行のセルは一度に高くなり、その背景が、下がってくる途中の下の行を隠すため。
        // `zPosition`を上げるとバーの下のぼかしより手前に出てしまうため、同じ`zPosition`のビューどうしの並び順で手前に出す（`MediaBarLayering`と同じ）。
        var moved: [UIView] = []
        for (id, old) in before {
            if let row = after[id] {
                // 高さが変わった行は、上端と下端のうち動きの小さいほうで測る。上端だけで測ると、下端を保って上へ伸びた行を、伸びた分だけ下から滑らせてしまい、伸びた中身が下の行に重なる。
                let shift = [row.minY - old.minY, row.maxY - old.maxY].min { abs($0) < abs($1) } ?? 0
                if shiftRow(row.cell.layer, by: shift, duration: duration) {
                    moved.append(row.cell)
                }
            } else if let indexPath = dataSource.indexPath(for: id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                // 押し下げられて表示領域の外へ出た行は、タイムラインがセルを外すので、描き直す前に取っておいた像を動かして外へ送る。
                let minY = collectionView.convert(frame, to: nil).minY
                sendOut(old.snapshot, from: old.minY, to: minY, duration: duration)
            }
        }
        let edgeShifts = rowEdgeShifts(before: before.mapValues { ($0.minY, $0.maxY) }, after: after.mapValues { ($0.minY, $0.maxY) }, resized: ids)
        for (id, row) in after where before[id] == nil {
            guard let shift = edgeShifts[id]?.top else { continue }
            if shiftRow(row.cell.layer, by: shift, duration: duration) {
                moved.append(row.cell)
            }
        }
        for (key, separator) in visibleSeparators() {
            let shift: CGFloat? = if let old = separatorsBefore[key]?.minY {
                separator.minY - old
            } else {
                // 行の下端に付く区切り線なので、その行の下端と同じだけ動かす。
                after.filter { $0.value.minY <= separator.minY && separator.minY <= $0.value.maxY + 1 }
                    .min { abs($0.value.maxY - separator.minY) < abs($1.value.maxY - separator.minY) }
                    .flatMap { edgeShifts[$0.key]?.bottom }
            }
            if let shift, shiftRow(separator.view.layer, by: shift, duration: duration) {
                moved.append(separator.view)
            }
        }
        for view in moved {
            collectionView.bringSubviewToFront(view)
        }
    }

    /// 描き直したあとに見えている行の、上端と下端が描き直しで動いた長さ（画面の座標）。
    /// 描き直す前は表示領域の外にあり、描き直して表示領域に入った行（長い本文を折りたたんで、下の行が上がってきたなど）は、前の位置が分からないので、
    /// 前から出ていた一番近い行から求める。高さが変わるのは描き直した行だけなので、そのあいだに並ぶ行は、上にある前から出ていた行の下端と同じだけ動いている。
    /// 上に前から出ていた行がなければ、下にある前から出ていた行の上端に合わせる。あいだに、前の高さの分からない描き直した行があれば求めない。
    private func rowEdgeShifts(before: [ItemID: (minY: CGFloat, maxY: CGFloat)], after: [ItemID: (minY: CGFloat, maxY: CGFloat)], resized: Set<ItemID>) -> [ItemID: (top: CGFloat, bottom: CGFloat)] {
        let order = after.keys.compactMap { id in dataSource.indexPath(for: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        var shifts: [ItemID: (top: CGFloat, bottom: CGFloat)] = [:]
        for id in order {
            guard let new = after[id], let old = before[id] else { continue }
            shifts[id] = (new.minY - old.minY, new.maxY - old.maxY)
        }
        func nearest(from index: Int, step: Int, edge: ((top: CGFloat, bottom: CGFloat)) -> CGFloat) -> CGFloat? {
            var cursor = index + step
            while order.indices.contains(cursor) {
                let id = order[cursor]
                if before[id] != nil { return shifts[id].map(edge) }
                if resized.contains(id) { return nil }
                cursor += step
            }
            return nil
        }
        for (index, id) in order.enumerated() where before[id] == nil && !resized.contains(id) {
            guard let shift = nearest(from: index, step: -1, edge: \.bottom) ?? nearest(from: index, step: 1, edge: \.top) else { continue }
            shifts[id] = (shift, shift)
        }
        return shifts
    }

    /// `reconfigureShiftingRowsBelow`が、`duration`で動かしてつなぐか。動かさないときは、動きなしで描き直す。
    private func animatesRowShift(duration: TimeInterval) -> Bool {
        duration > 0 && view.window != nil && !UIAccessibility.isReduceMotionEnabled
    }

    /// タイムラインに並ぶ区切り線のビューと、その画面（ウインドウ）での上端。区切り線はUIKitの非公開のビューなので、行のセルでも背景でもない、高さが細い線のビューとして見分ける。
    private func visibleSeparators() -> [ObjectIdentifier: (view: UIView, minY: CGFloat)] {
        collectionView.subviews.reduce(into: [:]) { result, view in
            guard !(view is UICollectionViewCell), !view.isHidden, view.bounds.height <= 2, view.bounds.width > 0 else { return }
            result[ObjectIdentifier(view)] = (view, view.convert(view.bounds, to: nil).minY)
        }
    }

    /// 行の中身の部品と、描き直す前の、親の座標での上端、高さ、隠れていたか、行のセルの座標での枠。
    private typealias RowPart = (view: UIView, minY: CGFloat, height: CGFloat, wasHidden: Bool, frameInCell: CGRect)

    /// 行の中身のビューと、その部品。中身が投稿でも通知でもない行ではnil。
    private func rowParts(of cell: UICollectionViewCell) -> (content: UIView, parts: [RowPart])? {
        let content = cell.contentView
        guard let body = (content as? PostContentView)?.postBody ?? (content as? NotificationContentView)?.postBody else { return nil }
        // 本文が、消えていく部品の代わりにいっとき重ねている像は、本文が自分で薄くして外すので、部品に数えない。数えると、新しく現れた部品として切り抜き、見えていた像が最初のコマで隠れる。
        let transient = body.transientSnapshots
        let views = content.subviews + body.subviews.filter { view in !transient.contains { $0 === view } }
        return (content, views.map { ($0, $0.frame.minY, $0.frame.height, $0.isHidden, $0.convert($0.bounds, to: cell)) })
    }

    /// `growth`だけ伸びた行（縮んだなら負）の中身を、前の画面上の位置から新しい位置へ動かす。
    /// 行の中の座標で位置が変わった部品は、前の位置から、下の行や区切り線と同じスプリングで動かす。動かさないと、行の下端に付いた部品（アクションバーなど）が一度に移り、
    /// すぐ下の区切り線だけが動いて見える。本文が自分で付ける動き（届いた絵文字、訳文、本文より下の部品）は、そのまま使う。
    ///
    /// 伸びた部品は、前の高さから切り抜きを広げる。新しく現れた部品（描き直す前は隠れていたか、なかった部品）は、最後の位置に置いたまま切り抜きを広げる。
    /// 下に前から出ていた部品があれば、切り抜きの下の端をその部品の上の端に合わせて動かす。現れた部品の上の端から広げると、本文の下の部品（画像、Xの投稿の囲みなど）が、下がってくるアクションバーより先に見え、重なる。
    /// 切り抜かないと、伸びた分や現れた部品が、動いている途中のまわりの部品に重なる。
    ///
    /// 下端を保って上へ伸び縮みした行（`keepsBottom`）では、中身全体を、伸びた分だけ下から動かす。部品の動きと足し合わさり、変わった箇所より下の部品は差し引きで止まり、上の部品だけが動く。
    /// 新しく現れた部品は、中身全体の動きを打ち消して、下の端から現す。上の部品が上へ退くのに合わせて現れる。
    ///
    /// 縮んだときは、なくなった部品の場所に、描き直す前の像を見せる。
    /// - Parameter snapshot: 描き直す前の行の像。
    private func shiftParts(of cell: UICollectionViewCell, from before: (content: UIView, parts: [RowPart])?, growth: CGFloat, keepsBottom: Bool, snapshot: UIView?, oldHeight: CGFloat, duration: TimeInterval) {
        guard let before, before.content === cell.contentView, abs(growth) > 0.5 else { return }
        // 部品のビューには、現れるときに初めて作られるものがある（リンクカードなど）。前の一覧にないものも、隠れていた部品と同じに扱う。
        let known = Set(before.parts.map { ObjectIdentifier($0.view) })
        let created = (rowParts(of: cell)?.parts ?? []).filter { !known.contains(ObjectIdentifier($0.view)) }.map { RowPart($0.view, 0, 0, true, .zero) }
        let staying = before.parts.filter { !$0.wasHidden && !$0.view.isHidden }
        for part in before.parts + created where !part.view.isHidden {
            let view = part.view
            if part.wasHidden {
                if keepsBottom {
                    shiftRow(view.layer, by: growth, duration: duration)
                    revealPart(view, from: max(view.bounds.height - growth, 0), anchoredAtBottom: true, duration: duration)
                } else if let edge = followedEdge(of: view, in: cell, among: staying) {
                    revealPart(view, followingEdgeFrom: edge.from, to: edge.to, duration: duration)
                } else {
                    revealPart(view, from: 0, anchoredAtBottom: false, duration: duration)
                }
            } else {
                if view.layer.animation(forKey: PostBodyView.belowTextShiftName) == nil {
                    shiftRow(view.layer, by: view.frame.minY - part.minY, duration: duration)
                }
                revealPart(view, from: part.height, anchoredAtBottom: false, duration: duration)
            }
        }
        if keepsBottom {
            shiftRow(before.content.layer, by: -growth, duration: duration)
        }
        if growth < 0, let snapshot, let cell = cell as? TimelineCell {
            if keepsBottom {
                concealUpwardShrink(of: cell, with: snapshot, parts: before.parts, oldHeight: oldHeight, shrink: -growth, duration: duration)
            } else {
                concealDownwardShrink(of: cell, with: snapshot, parts: before.parts, oldHeight: oldHeight, shrink: -growth, duration: duration)
            }
        }
    }

    /// 上端を保って下へ縮んだ行で、なくなった部品と、縮んだ部品のなくなった下の部分に、描き直す前の像のその部分を見せ、下の部品が上がってくるのに合わせて、下の端から縮める。
    /// 見せないと、なくなった中身の場所が、下の部品が上がってくるまで空く。行全体の像は見せない。像には、動いている下の部品（アクションバーなど）も写っているので、本物と二重になる。
    /// 本文を載せた入れ物は扱わない。中の部品がなくなって縮むので、なくなったのは下の部分ではないため。
    private func concealDownwardShrink(of cell: TimelineCell, with snapshot: UIView, parts: [RowPart], oldHeight: CGFloat, shrink: CGFloat, duration: TimeInterval) {
        let areas = parts.compactMap { part -> CGRect? in
            guard !part.wasHidden, part.frameInCell.height > 0.5, !(part.view is PostBodyView) else { return nil }
            if part.view.isHidden { return part.frameInCell }
            // 出たまま縮んだ本文は、なくなった文字を自分で薄くして消す（`EmojiLabel.prepareTextEdit`）。像を見せると、動いている文字と、像の中の文字が食い違う。
            guard !(part.view is EmojiLabel) else { return nil }
            let lost = part.frameInCell.height - part.view.bounds.height
            guard lost > 0.5 else { return nil }
            return CGRect(x: part.frameInCell.minX, y: part.frameInCell.maxY - lost, width: part.frameInCell.width, height: lost)
        }
        guard let first = areas.first else { return }
        let area = areas.dropFirst().reduce(first) { $0.union($1) }
        snapshot.isUserInteractionEnabled = false
        snapshot.frame = CGRect(x: 0, y: 0, width: cell.bounds.width, height: oldHeight)
        cell.showShrinkSnapshot(snapshot)
        let mask = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = .zero
        mask.bounds = CGRect(x: 0, y: 0, width: cell.bounds.width, height: 0)
        mask.position = CGPoint(x: 0, y: area.minY)
        CATransaction.commit()
        // 下の部品は、縮んだ分だけ上がってくる。切り抜きの下の端を、その上の端と一緒に動かす。切り抜きは、なくなった部品の枠の中から始める（`concealUpwardShrink`と同じ）。
        let conceal = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        conceal.fromValue = min(shrink, area.height)
        conceal.toValue = 0
        conceal.delegate = RowShiftCompletion { [weak cell, weak snapshot] in
            guard let cell, let snapshot else { return }
            cell.removeShrinkSnapshot(snapshot)
        }
        mask.add(conceal, forKey: Self.shrinkName)
        snapshot.layer.mask = mask
    }

    /// 下端を保って上へ縮んだ行で、なくなった部品（描き直す前は出ていて、今は隠れている部品）のあった場所に、描き直す前の像のその部分を見せ、上の中身が下りてくるのに合わせて、上の端から縮める。
    /// 見せないと、なくなった部品の場所が、上の中身が下りてくるまで空く。下へ縮むときの`concealDownwardShrink`の、向きを逆にしたもの。
    /// 高さが減っただけの部品は扱わない。どこがなくなったかが分からないため。本文は、なくなった文字を自分で薄くして消す。
    private func concealUpwardShrink(of cell: TimelineCell, with snapshot: UIView, parts: [RowPart], oldHeight: CGFloat, shrink: CGFloat, duration: TimeInterval) {
        let gone = parts.filter { !$0.wasHidden && $0.view.isHidden && $0.frameInCell.height > 0.5 }.map(\.frameInCell)
        guard let first = gone.first else { return }
        let area = gone.dropFirst().reduce(first) { $0.union($1) }
        snapshot.isUserInteractionEnabled = false
        // 像は、下端を今の行の下端に合わせて置く。行は下端を保って縮んだので、像の中の部品は、描き直す前と同じ画面上の位置に来る。
        snapshot.frame = CGRect(x: 0, y: cell.bounds.height - oldHeight, width: cell.bounds.width, height: oldHeight)
        cell.showShrinkSnapshot(snapshot)
        let mask = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 1)
        mask.bounds = CGRect(x: 0, y: 0, width: cell.bounds.width, height: 0)
        mask.position = CGPoint(x: 0, y: area.maxY)
        CATransaction.commit()
        // 上の中身は、縮んだ分だけ下りてくる。切り抜きの上の端を、その下の端と一緒に動かす。
        // 切り抜きは、なくなった部品の枠の中から始める。縮んだ分には部品とのすき間も入っているので、縮んだ分から始めると、下りてくる中身の下の端と、像の上の端が重なる。
        let conceal = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        conceal.fromValue = min(shrink, area.height)
        conceal.toValue = 0
        conceal.delegate = RowShiftCompletion { [weak cell, weak snapshot] in
            guard let cell, let snapshot else { return }
            cell.removeShrinkSnapshot(snapshot)
        }
        mask.add(conceal, forKey: Self.shrinkName)
        snapshot.layer.mask = mask
    }

    /// 伸びた部品を、`height`から今の高さまで切り抜いて見せる。`anchoredAtBottom`なら下の端から、そうでなければ上の端から広げる。
    /// 切り抜きを広げている途中にまた伸びたら（絵文字が続けて届いたなど）、同じ切り抜きを、今見えている高さから新しい高さへ動かし直す。
    /// 動かし直さないと、切り抜きは前の高さまでしか広がらず、足された分が、切り抜きを外すコマで一度に現れる。
    private func revealPart(_ view: UIView, from height: CGFloat, anchoredAtBottom: Bool, duration: TimeInterval) {
        let newHeight = view.bounds.height
        guard newHeight - height > 0.5 else { return }
        // 上の端から広げる切り抜きは、下の部品に合わせて現すときと同じ形にする。形を分けると、広げている途中にまた伸びたとき、今見えている下の端を読み違える。
        guard anchoredAtBottom else {
            revealPart(view, followingEdgeFrom: height, to: newHeight, duration: duration)
            return
        }
        let running = view.layer.mask.flatMap { $0.name == Self.partRevealName ? $0 : nil }
        guard running != nil || view.layer.mask == nil else { return }
        let mask = running ?? CALayer()
        let from = running?.presentation()?.bounds.height ?? height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.name = Self.partRevealName
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 1)
        mask.bounds = CGRect(origin: .zero, size: view.bounds.size)
        mask.position = CGPoint(x: 0, y: newHeight)
        CATransaction.commit()
        let grow = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        grow.fromValue = from
        grow.toValue = newHeight
        grow.delegate = RowShiftCompletion { [weak view, weak mask] in
            // 動かし直した動きが続いていれば外さない。
            guard let view, let mask, view.layer.mask === mask, mask.animation(forKey: Self.partRevealName) == nil else { return }
            view.layer.mask = nil
        }
        mask.add(grow, forKey: Self.partRevealName)
        view.layer.mask = mask
    }

    /// 新しく現れた部品のすぐ下にあり、描き直す前から出ていた部品の上端の、描き直す前と後の位置を、現れた部品の座標で返す。下に出ていた部品がなければnil。
    /// 下の部品は、前の位置から新しい位置へ動く。現れた部品の切り抜きの下端をその上端に合わせて動かせば、下がってくる部品（アクションバーなど）が、現れた部品に重ならない。
    private func followedEdge(of view: UIView, in cell: UICollectionViewCell, among staying: [RowPart]) -> (from: CGFloat, to: CGFloat)? {
        let frame = view.convert(view.bounds, to: cell)
        let below = staying.compactMap { part -> (old: CGFloat, new: CGFloat)? in
            guard part.view !== view, !part.view.isDescendant(of: view), !view.isDescendant(of: part.view) else { return nil }
            let new = part.view.convert(part.view.bounds, to: cell)
            guard new.minY >= frame.maxY - 0.5, new.maxX > frame.minX, new.minX < frame.maxX else { return nil }
            return (part.frameInCell.minY, new.minY)
        }
        guard let next = below.min(by: { $0.new < $1.new }), next.new - next.old > 0.5 else { return nil }
        return (next.old - frame.minY, next.new - frame.minY)
    }

    /// 現れた部品を、切り抜きの下端を`from`から`to`（部品の座標）へ、下の部品と同じスプリングで動かして見せる。`from`は部品の上端より上（負）でもよい。
    /// 切り抜きを広げている途中なら、今見えている下端から動かし直す。
    private func revealPart(_ view: UIView, followingEdgeFrom from: CGFloat, to: CGFloat, duration: TimeInterval) {
        let running = view.layer.mask.flatMap { $0.name == Self.partRevealName ? $0 : nil }
        guard running != nil || view.layer.mask == nil else { return }
        let mask = running ?? CALayer()
        let start = running?.presentation().map { $0.position.y + (1 - $0.anchorPoint.y) * $0.bounds.height } ?? from
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.name = Self.partRevealName
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = .zero
        mask.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: to)
        mask.position = .zero
        CATransaction.commit()
        let follow = CASpringAnimation.rowSpring(keyPath: "position.y", duration: duration)
        follow.fromValue = start - to
        follow.toValue = 0
        follow.delegate = RowShiftCompletion { [weak view, weak mask] in
            guard let view, let mask, view.layer.mask === mask, mask.animation(forKey: Self.partRevealName) == nil else { return }
            view.layer.mask = nil
        }
        mask.add(follow, forKey: Self.partRevealName)
        view.layer.mask = mask
    }

    /// 伸びた部品を現す切り抜きの動きの名前。
    static let partRevealName = "rowPartReveal"

    /// 行の中身の下の端（行のセルの座標）。行の高さから下の余白を引いたもの。下の余白が分からない行では、行の下端。
    private func contentBottom(of cell: UICollectionViewCell) -> CGFloat {
        let margin = (cell.contentView as? PostContentView)?.rowBottomMargin ?? (cell.contentView as? NotificationContentView)?.rowBottomMargin ?? 0
        return cell.bounds.height - margin
    }

    /// 行の高さの変化を、下の行ごと動かして描き直している最中。描き直す行の中身に、本文の文字も動かしてよいと伝える。
    private(set) var isShiftingRows = false

    /// 足し合わせる行の動きに付ける名前を、重ねても取り替えないよう分ける。
    private var rowShiftCount = 0

    /// 層を、`shift`だけ前の位置から今の位置へ動かす。前の動きの途中なら、その動きは足し合わせたまま続く。動かしたらtrueを返す。
    @discardableResult
    private func shiftRow(_ layer: CALayer, by shift: CGFloat, duration: TimeInterval) -> Bool {
        guard abs(shift) > 0.5 else { return false }
        let move = CASpringAnimation.rowSpring(keyPath: "position", duration: duration)
        move.isAdditive = true
        move.fromValue = CGPoint(x: 0, y: -shift)
        move.toValue = CGPoint.zero
        rowShiftCount += 1
        layer.add(move, forKey: "rowShift\(rowShiftCount)")
        return true
    }

    /// 伸びた行のセルを、下の行の動きと同じスプリングで、前の高さから新しい高さまで切り抜いて見せる。
    /// 伸びた行の中身は一度に新しい高さで並ぶため、切り抜かないと、不透明なセルの背景と中身が、下がってくる途中の下の行と、押し出される行の像を覆う。
    /// 像はタイムラインに足すが、タイムラインが並べ直すときにセルを手前へ戻すので、重なり順では避けられない。
    /// 伸びている途中にまた伸びたら（広げている途中に絵文字が届いて折り返しが増えたなど）、同じ切り抜きを、今見えている高さから新しい高さへ動かし直す。
    private func revealGrowth(of cell: UICollectionViewCell, from oldHeight: CGFloat, duration: TimeInterval) {
        let newHeight = cell.bounds.height
        let running = cell.layer.mask.flatMap { $0.name == Self.growthMaskName ? $0 : nil }
        guard newHeight - oldHeight > 0.5, running != nil || cell.layer.mask == nil else { return }
        let mask = running ?? CALayer()
        let from = running?.presentation()?.bounds.height ?? oldHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.name = Self.growthMaskName
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = .zero
        mask.frame = cell.layer.bounds
        CATransaction.commit()
        let grow = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        grow.fromValue = from
        grow.toValue = newHeight
        grow.delegate = RowShiftCompletion { [weak cell, weak mask] in
            // 動かし直した動きが続いていれば外さない。動きの途中で使い回されて、ほかの切り抜きに替わっていたら、そちらも外さない。
            guard let cell, let mask, cell.layer.mask === mask, mask.animation(forKey: Self.growthMaskName) == nil else { return }
            cell.layer.mask = nil
        }
        mask.add(grow, forKey: Self.growthMaskName)
        cell.layer.mask = mask
    }

    private static let growthMaskName = "rowGrowth"

    /// 表示領域の外へ出た行の像を、前の位置から新しい位置へ動かしてから外す。
    private func sendOut(_ snapshot: UIView?, from oldMinY: CGFloat, to newMinY: CGFloat, duration: TimeInterval) {
        guard let snapshot, abs(newMinY - oldMinY) > 0.5 else { return }
        snapshot.isUserInteractionEnabled = false
        collectionView.addSubview(snapshot)
        let origin = collectionView.convert(CGPoint(x: 0, y: newMinY), from: nil)
        snapshot.frame.origin.y = origin.y
        shiftRow(snapshot.layer, by: newMinY - oldMinY, duration: duration)
        // 像を動かすスプリングが止まるまで残す。
        let remove = CABasicAnimation(keyPath: "opacity")
        remove.fromValue = 1
        remove.toValue = 1
        remove.duration = CASpringAnimation.rowSpring(keyPath: "position", duration: duration).settlingDuration
        remove.delegate = RowShiftCompletion { snapshot.removeFromSuperview() }
        snapshot.layer.add(remove, forKey: "rowShiftEnd")
    }

    /// 見えている行の、画面（ウインドウ）での上端と下端と、表示領域の外へ押し出されたときに動かす像。
    /// 画面の座標で比べるのは、読んでいる位置を保つためにスクロール位置を補正した分を、行の動きに数えないため。
    /// 動きの途中の行も、動きを足す前の位置で測る。前の動きは足し合わせたまま続くので、次の動きはずれた分だけを足せばつながる。
    /// - Parameter changed: 描き直す行。像は、そのうち一番上の見えている行より下の行だけ取る。行が大きく伸びると、その下の何行もが外へ押し出されるため。
    /// - Parameter shiftLimit: 行が動く長さの上限。渡すと、その長さだけ上か下へ動いたらタイムラインの外へ出る行の像だけを取る。
    /// 行が伸びれば下の行は下へ、縮めば上へ動き、どちらの端から出るかは、位置を保つ行がどこにあるかで変わるため、両方の端で決める。
    private func visibleRows(snapshottingBelow changed: Set<ItemID>, within shiftLimit: CGFloat? = nil) -> [ItemID: (cell: UICollectionViewCell, minY: CGFloat, maxY: CGFloat, snapshot: UIView?)] {
        let rows: [(id: ItemID, cell: UICollectionViewCell, frame: CGRect)] = collectionView.visibleCells.compactMap { cell in
            guard let id = collectionView.indexPath(for: cell).flatMap({ dataSource.itemIdentifier(for: $0) }) else { return nil }
            return (id, cell, cell.convert(cell.bounds, to: nil))
        }
        let changedTop = rows.filter { changed.contains($0.id) }.map(\.frame.minY).min()
        let bounds = collectionView.convert(collectionView.bounds, to: nil)
        return rows.reduce(into: [:]) { result, row in
            let isBelow = changedTop.map { row.frame.minY > $0 } == true
            let mayLeave = shiftLimit.map { row.frame.minY + $0 > bounds.maxY || row.frame.maxY - $0 < bounds.minY } ?? true
            let snapshot = isBelow && mayLeave ? row.cell.snapshotView(afterScreenUpdates: false) : nil
            snapshot?.frame = row.cell.frame
            result[row.id] = (row.cell, row.frame.minY, row.frame.maxY, snapshot)
        }
    }

    /// 押し出された行の像を、動き終えたら外す。
    @MainActor
    private final class RowShiftCompletion: NSObject, @MainActor CAAnimationDelegate {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func animationDidStop(_ animation: CAAnimation, finished: Bool) {
            handler()
        }
    }

    /// 通知のアイコンは文字に差し込んでいるため、届いたらその人からの通知を描き直す。投稿のアイコンはビューが自分で受け取る。
    private func avatarImageDidLoad(_ key: AvatarImageKey) {
        let ids = dataSource.snapshot().itemIdentifiers.filter { id in
            guard case .notification(let notification) = entries[id] else { return false }
            return avatarContent(of: notification.account).url == key.url
        }
        reconfigure(Set(ids))
    }

    /// 引用の囲みに出す引用元の本文、注意書き、作者の名前の絵文字も含める。引用元は、囲みと同じく受け取ったあとの変化を当てた版から集める。
    static func emojiURLs(of status: Status, quoteSources: QuoteSourceChanges, localReactionEmojis: [String: CustomEmoji] = [:], accountEmojis: (Account) -> [CustomEmoji]) -> Set<URL> {
        let shown = status.displayed
        let quoted = quoteSources.applying(to: shown).quote?.quotedStatus.map { $0.emojis + accountEmojis($0.account) } ?? []
        let reactions = shown.emojiReactions.compactMap { $0.emoji.resolvingImage(in: localReactionEmojis).customEmoji }
        return imageURLs(of: shown.emojis + (shown.poll?.emojis ?? []) + accountEmojis(shown.account) + accountEmojis(status.account) + quoted + reactions)
    }

    /// 絵文字の画像のURL。描く場所によって元の画像と動かない版のどちらを読むかが違うので、両方を入れる。
    private static func imageURLs(of emojis: [CustomEmoji]) -> Set<URL> {
        Set(emojis.flatMap { [$0.url, $0.staticUrl] })
    }

    private static func emojiURLs(of notification: MastodonNotification, quoteSources: QuoteSourceChanges, localReactionEmojis: [String: CustomEmoji], accountEmojis: (Account) -> [CustomEmoji]) -> Set<URL> {
        imageURLs(of: accountEmojis(notification.account) + [notification.reactionEmoji?.customEmoji].compactMap(\.self)).union(notification.status.map { emojiURLs(of: $0, quoteSources: quoteSources, localReactionEmojis: localReactionEmojis, accountEmojis: accountEmojis) } ?? [])
    }

    /// 端末の文字の大きさが変わったら、行をすべて組み直し、変わる前に読んでいた位置へ戻す。
    private func contentSizeDidChange() {
        let anchor = contentSizeAnchor ?? currentAnchor()
        contentSizeAnchor = nil
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        if let anchor {
            restore(anchor)
        }
    }

    /// 内容が変わってセルの高さが変わっても、読んでいる位置が動かないように描き直す。
    /// - Parameter anchorID: 画面上の位置を保つ要素。なければ、表示領域の上端にかかっている要素にする。
    func reconfigure(_ ids: Set<ItemID>, keeping anchorID: ItemID? = nil) {
        guard !ids.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(Array(ids))
        applyPreservingAnchor(snapshot, keeping: anchorID, resizing: ids)
    }

    /// アクションバーの引き出しを開いている投稿。同時に1つだけ開く。タイムラインを閉じるか起動し直すと閉じた状態に戻る（docs/post-action-bar.mdの「引き出し」）。
    var openActionBarItemID: ItemID?
    /// 「投稿の見た目」のプレビューで、いつも出す設定でなくてもアクションバーを出す。アクションバーの分類の見本で立てる。
    var showsActionBarInPreview = false

    /// 表示中の要素を、新しい順に並んだ`newEntries`で置き換える。
    ///
    /// 読んでいる位置の要素が画面上で動かないようにする。基準は表示領域の上端にかかっている要素で、`anchorID`を渡せばその要素にする。
    /// ただし最上部にいて追従が有効なら、最上部に留まって新着を見せる。ビューアや全画面のアプリ内のSafariで覆っている間は追従しない。
    /// `topID`を渡すと、その要素を表示領域の上端に置く。既読位置から読み始めるときに使う。
    /// - Parameter keepsOffset: タイムラインの中身を取り替える。要素を基準にせず、スクロール位置をそのまま保つ。
    ///   プロフィールのタブの切り替えのように、ヘッダーを押した場所に残し、その下の中身だけを入れ替えたいときに使う。
    ///   新しいタイムラインが短くていまの位置までスクロールできなければ、末尾までスクロールしたところで止める。
    /// - Parameter animatesRemoval: 使う人の操作（フォローリクエストの承認、投稿の削除など）で行を消す。
    ///   操作の結果が分かるよう、消える行を閉じ、下の行を詰める動きで消す。消せないときは、ほかの更新と同じく動かさずに位置を保つ。
    /// - Parameter base: `newEntries`は、この並びに行を足すか除くかしただけで、残る行の中身を変えていない。
    ///   前回並べた配列と同じものなら、描き直す行を探すために行の中身を比べるのを省く。タイムラインが長いと、比べるだけで重くなるため。
    func setEntries(_ newEntries: [TimelineEntry], keeping anchorID: ItemID? = nil, placingAtTop topID: ItemID? = nil, keepsOffset: Bool = false, animatesRemoval: Bool = false, keepingRowContentsOf base: [TimelineEntry]? = nil) {
        updateEntries(newEntries, keeping: anchorID, placingAtTop: topID, keepsOffset: keepsOffset, animatesRemoval: animatesRemoval, animatesChanges: false, keepingRowContentsOf: base)
        // 画面を出したときに、まだ並べる投稿がなかったら、並べたときに組んでおく。
        if viewIfLoaded?.window != nil {
            prepareActionBarIfNeeded()
        }
    }

    func transition(to newEntries: [TimelineEntry]) {
        updateEntries(newEntries, keeping: nil, placingAtTop: nil, keepsOffset: true, animatesRemoval: false, animatesChanges: true, keepingRowContentsOf: nil)
    }

    /// - Parameter animatesChanges: 使う人の操作の結果として、足す、消す、並べ替えるをどれも動きで見せる。動かせなければ`keepsOffset`などの指定どおりに置き換える。
    private func updateEntries(_ newEntries: [TimelineEntry], keeping anchorID: ItemID?, placingAtTop topID: ItemID?, keepsOffset: Bool, animatesRemoval: Bool, animatesChanges: Bool, keepingRowContentsOf base: [TimelineEntry]?) {
        // 閉じ終えていても、溜めた分を反映する前は溜める。先に反映すると、あとで古い溜めた分で上書きするため。
        guard swipeCloseTicker == nil, !isRowClosingSwipe else {
            // 後の呼び出しの並びが新しい。基準は、溜めるのをやめるときに最後に指定されたものを使う。
            heldEntries = HeldEntries(
                entries: newEntries,
                anchorID: anchorID ?? heldEntries?.anchorID,
                topID: topID ?? heldEntries?.topID,
                keepsOffset: keepsOffset || (heldEntries?.keepsOffset ?? false),
                // 操作によらない変化と混ざったら、どれが操作の結果か分からないため、動かさない。
                animatesRemoval: heldEntries == nil && animatesRemoval,
                animatesChanges: heldEntries == nil && animatesChanges
            )
            waitForSwipeToClose()
            return
        }
        let previous = entries
        // 読み込み中の表示から最初の行を出すときは、表示を薄くしながら行を浮かび上がらせる。
        // 読み込みが速く、読み込み中の表示を画面に置く前に行が届いたときも、行は浮かび上がらせる。
        let revealsFromLoading = contentState == .loading && headerView == nil && previous.isEmpty && !newEntries.isEmpty
        let loadingSnapshot = revealsFromLoading ? loadingViewSnapshot() : nil
        let keepsRowContents = base.map { Self.sharesStorage($0, appliedEntries) } ?? false
        appliedEntries = newEntries
        // 添付ファイルのビューアや全画面のアプリ内のSafariで覆っている間は、新着を見たと報告しないので、追従もせずに読んでいた行の位置を保つ。
        // ウィンドウが前面にない間は、画面に出ていて流れを眺めていることがあるため追従する。見たとは報告しないので、追従した新着は未読に残る。
        let isCovered = isCoveredByMediaViewer || isCoveredByInAppBrowser
        // メニューを出している間も追従しない。メニューの元になった行が、メニューの下で流れるため。
        let followsTop = anchorID == nil && topID == nil && isAtTop && !isCovered && !isShowingMenu && tuning.value(of: TuningCatalog.followsNewArrivalsAtTop)
        let newIDs = newEntries.map(\.id)
        // IDは元のまま、中身だけを読めない行にする。ストアは変えないので、既読位置や未読の数は隔離の影響を受けない。
        entries = Dictionary(zip(newIDs, newEntries.map(quarantined)), uniquingKeysWith: { _, new in new })
        reactionGlowSeparatorLeadings = reactionGlowSeparatorLeadings.filter { entries[$0.key] != nil }
        prunePostSelection()
        gapIDs = newEntries.compactMap { entry in
            if case .gap(let gap) = entry { gap.id } else { nil }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newIDs)
        // 差分はIDで取られるため、同じIDのまま内容が変わった要素は明示的にセルを再構成する。
        let changedIDs = keepsRowContents ? [] : newEntries.filter { entry in previous[entry.id].map { $0 != quarantined(entry) } ?? false }.map(\.id)
        // 隣の行が変わって線のつながりだけが変わった行も描き直す。線は行の高さを変えないため、消す動きを止める理由にはしない。
        // 線のない行は前後とも線がないので、線のあった行と、ある行だけを比べる。
        let previousConnections = replyConnections
        replyConnections = ReplyConnection.connections(in: newEntries)
        let reconnectedIDs = Set(previousConnections.keys).union(replyConnections.keys).filter { id in
            previous[id] != nil && entries[id] != nil && previousConnections[id] != replyConnections[id]
        }
        // 編集で本文か言語が変わった投稿の訳文は使えないので、見えている範囲が変わらなくても訳し直しを頼む。
        let bodyChanged = translations != nil && changedIDs.contains { id in
            let old = previous[id]?.postStatus?.displayed
            let new = entries[id]?.postStatus?.displayed
            return old?.content != new?.content || old?.language != new?.language
        }
        defer {
            if bodyChanged { requestTranslationsAroundVisibleRows() }
        }
        // 絵文字のリアクションだけが変わった行は、並びを置き換えたあとで、ボタンの出入りと数を動かし、高さが変わる分を下の行ごと動かして描き直す（docs/emoji-reaction.mdの「動き」）。
        let reactionChangedIDs = Set(changedIDs.filter { id in
            guard let old = previous[id]?.postStatus, let new = entries[id]?.postStatus else { return false }
            return new.differsOnlyInEmojiReactions(from: old)
        })
        // リアクションのボタンは、出入りを自分で動かすので、縮む前の像は重ねない。
        defer { reconfigureShiftingRowsBelow(reactionChangedIDs, keeping: anchorID, duration: tuning.value(of: TuningCatalog.reactionTransitionDuration), concealsShrink: false) }
        // ほかの中身が変わった行（編集、取り直した投稿など）は、高さが変わるものとして、並びを置き換えたあとで、下の行ごと動かして描き直す。
        // 高さを変えない中身だけが変わった行は、下の行の像を取らずに済むよう、並びと一緒に動かさずに描き直す。
        // 並びも変わるときは、行の出入りと高さの変化が重なり、位置を保つ基準が並びの置き換えと描き直しとで変わるので、並びと一緒に動かさずに描き直す。
        let keepsOrder = dataSource.snapshot().itemIdentifiers == newIDs
        let resizedIDs = !keepsOrder ? [] : Set(changedIDs.filter { id in
            guard let old = previous[id]?.postStatus, let new = entries[id]?.postStatus else { return true }
            return !new.differsOnlyInFixedHeightParts(from: old)
        }).subtracting(reactionChangedIDs)
        defer {
            reconfigureShiftingRowsBelow(resizedIDs, keeping: anchorID, duration: tuning.value(of: TuningCatalog.linkCardTransitionDuration))
            // 取り直す投稿は、行に出している中身から決める。下の`reportVisibleItems`は、ここで描き直す前の中身を読むので、描き直したあとに報告し直す。
            // 報告し直さないと、編集でリンクが足された投稿のカードを、次にスクロールするまで取り直さない。
            if !resizedIDs.isEmpty {
                reportVisibleItems()
            }
        }
        snapshot.reconfigureItems(Array(reconnectedIDs.union(changedIDs).subtracting(resizedIDs).subtracting(reactionChangedIDs)))
        if animatesRemoval, changedIDs.isEmpty, canAnimateRemoval(leaving: newIDs) {
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: true) }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) animatesRemoval=true")
        } else if animatesChanges, !revealsFromLoading, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            // 読み込み中の表示から最初の行を出すときは、下で行を浮かび上がらせるので、ここでは動かさない。
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: true) }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) animatesChanges=true")
        } else if let topID {
            isRestoringAnchor = true
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
            scrollToTop(of: topID)
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) top=\(Self.label(topID), privacy: .public)")
        } else if keepsOffset {
            isRestoringAnchor = true
            let offset = collectionView.contentOffset.y
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
            collectionView.layoutIfNeeded()
            let inset = collectionView.adjustedContentInset
            let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
            collectionView.contentOffset.y = min(offset, maxOffset)
            isRestoringAnchor = false
            logger.info("setEntries count=\(newEntries.count, privacy: .public) keepsOffset=true")
        } else if followsTop {
            // 最初に並べるときは、行が浮かび上がって見えないよう、アニメーションしない。
            let animates = !previous.isEmpty && settings.insertionMotion.animates(reducesMotion: UIAccessibility.isReduceMotionEnabled)
            if animates {
                // 行はアニメーションなしで足し、いままで最上部にあった行を同じ位置に残す。足した行の高さぶん下にずれた位置から、
                // 最上部へ1つの動きで戻して新着を見せる。
                applyPreservingAnchor(snapshot)
                scrollToTop(
                    duration: tuning.value(of: TuningCatalog.insertionScrollDuration),
                    bounce: tuning.value(of: TuningCatalog.insertionScrollBounce)
                )
            } else {
                isRestoringAnchor = true
                FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
                collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
                isRestoringAnchor = false
            }
            logger.info("setEntries count=\(newEntries.count, privacy: .public) followsTop=true animated=\(animates, privacy: .public)")
        } else {
            // このあと下の行ごと動かして描き直す行も、高さが変わるので、位置を保つ基準にしない。
            let anchor = applyPreservingAnchor(snapshot, keeping: anchorID, resizing: Set(snapshot.reconfiguredItemIdentifiers).union(resizedIDs).union(reactionChangedIDs))
            logger.info("setEntries count=\(newEntries.count, privacy: .public) anchor=\(anchor.map { Self.label($0.id) } ?? "nil", privacy: .public)")
        }
        if threadFocusID != nil {
            updateBottomInset()
        }
        setNeedsUpdateContentUnavailableConfiguration()
        if revealsFromLoading {
            revealFirstEntries(over: loadingSnapshot)
        }
        reportVisibleItems()
        reportApproachingGaps()
        updateNewArrivalsButtonArrow()
    }

    /// 全面に出している読み込み中の表示の像を、同じ位置に重ねて返す。表示を外したあとも、薄くし終えるまで残すため。
    private func loadingViewSnapshot() -> UIView? {
        let duration = tuning.value(of: TuningCatalog.accountSwitchDuration)
        guard duration > 0, view.window != nil, contentUnavailableConfiguration != nil,
              let shown = view.subviews.first(where: { $0 is UIContentUnavailableView }),
              let snapshot = shown.snapshotView(afterScreenUpdates: false)
        else { return nil }
        snapshot.frame = shown.frame
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        return snapshot
    }

    /// 読み込み中の表示を外して最初の行を出したとき、表示の像を薄くし、見えている行を浮かび上がらせる。1コマで入れ替えないため。
    /// アカウントを切り替えたときと起動したときの、最初の読み込みで通る。
    private func revealFirstEntries(over loadingSnapshot: UIView?) {
        let duration = tuning.value(of: TuningCatalog.accountSwitchDuration)
        if let loadingSnapshot {
            UIView.animateSpring(duration: duration * 0.6, in: loadingSnapshot) {
                loadingSnapshot.alpha = 0
            } completion: {
                loadingSnapshot.removeFromSuperview()
            }
        }
        fadeInVisibleItems(duration: duration)
    }

    /// 行を消すだけの更新を、閉じる動きで当てられるか。
    /// 行を足すときと、表示領域の上端より上の行が消えるときは動かさない。上の行を詰めると、読んでいる行が上へずれるため。
    /// 残る行の中身が変わるときも、呼び出し側で除く。高さが変わると、読んでいる行がずれうるため。
    /// 視差効果を減らす設定では、動きで伝えずに消す。
    private func canAnimateRemoval(leaving newIDs: [ItemID]) -> Bool {
        guard view.window != nil, !UIAccessibility.isReduceMotionEnabled else { return false }
        let currentIDs = dataSource.snapshot().itemIdentifiers
        let remaining = Set(newIDs)
        let removed = currentIDs.filter { !remaining.contains($0) }
        guard !removed.isEmpty, remaining.isSubset(of: currentIDs) else { return false }
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return removed.allSatisfy { id in
            guard let indexPath = dataSource.indexPath(for: id),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return false }
            return frame.minY >= visibleTop
        }
    }

    /// 画面に見えている行を、透明からフェードで出す。行を入れた直後に呼ぶ。
    /// タイムライン全体をクロスフェードすると、途中でスクロールしたときに前の見た目が残像として重なるため、行だけを動かす。
    /// フェードの途中にスクロールで入ってきた行は、フェードせずにそのまま出す。0秒か、画面に出ていなければ何もしない。
    func fadeInVisibleItems(duration: TimeInterval) {
        guard duration > 0, view.window != nil else { return }
        collectionView.layoutIfNeeded()
        let cells = collectionView.visibleCells
        for cell in cells {
            cell.alpha = 0
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
            for cell in cells {
                cell.alpha = 1
            }
        }
    }

    /// 読み込み中のギャップを読み込み中の表示に、読めなかったギャップを読めなかった表示にする。
    func setGapStates(loading ids: Set<String>, failures: [String: ErrorPresentation]) {
        let failureChanged = Set(failures.keys).union(gapFailures.keys).filter { failures[$0] != gapFailures[$0] }
        let changed = ids.symmetricDifference(loadingGapIDs).union(failureChanged).map(ItemID.gap)
        loadingGapIDs = ids
        gapFailures = failures
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        reconfigure(Set(changed).intersection(existing))
    }

    /// 最上部にいる。新着を挿入したときに追従するかの判定に使う。
    var isAtTop: Bool {
        collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5
    }

    /// 指でスクロールしている、または指を離した後の慣性で動いている。
    var isUserScrolling: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    /// スクロールしている、またはまとめて行う操作のために投稿を選んでいる。モデルが新着を挿入するのは、これが終わってからにする。
    /// 選んでいる間に新着で行がずれると、押そうとした行を押し損なうため。
    /// コンテキストメニューを出している間は含めない。新着は、追従せずに位置を保って、すぐ上に積む。
    var isUserInteracting: Bool {
        isUserScrolling || isSelectingPosts
    }

    /// 2つの配列が同じ記憶域を指している。指していれば、中身も同じ。
    /// 前回並べた配列をここで持っているので、渡した側が並びを書き換えると、書き換えた側の配列は別の記憶域へコピーされる。
    /// 同じ中身でも記憶域が違えばfalseになり、そのときは行の中身を比べる。
    private static func sharesStorage(_ lhs: [TimelineEntry], _ rhs: [TimelineEntry]) -> Bool {
        lhs.count == rhs.count && lhs.withUnsafeBufferPointer { lhs in
            rhs.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
        }
    }

    private struct HeldEntries {
        let entries: [TimelineEntry]
        let anchorID: ItemID?
        let topID: ItemID?
        let keepsOffset: Bool
        let animatesRemoval: Bool
        let animatesChanges: Bool
    }

    /// コンテキストメニューを出した。出している間は、最上部にいても新着に追従しない。新着を含む並びの更新と描き直しは、読んでいる行の位置を保って、すぐ反映する。
    /// 最上部で出している間に新着が入ると、上に積まれて最上部ではなくなるので、閉じたあとも追従には戻らず、新着のボタンで出す。
    func menuWillShow() {
        isShowingMenu = true
        logger.info("menu will show")
    }

    /// メニューが閉じた。
    func menuDidHide() {
        guard isShowingMenu else { return }
        isShowingMenu = false
        logger.info("menu did hide")
        if let pending = pendingTextSelection {
            pendingTextSelection = nil
            // 開いている間の更新で、行が別の投稿に使い回されていれば選ばない。
            if pending.body.content?.statusID == pending.statusID {
                beginTextSelection(in: pending.body, statusID: pending.statusID)
            }
        }
    }

    private func applyHeldEntries() {
        guard let held = heldEntries else { return }
        heldEntries = nil
        updateEntries(held.entries, keeping: held.anchorID, placingAtTop: held.topID, keepsOffset: held.keepsOffset, animatesRemoval: held.animatesRemoval, animatesChanges: held.animatesChanges, keepingRowContentsOf: nil)
    }

    /// スワイプのボタンを閉じる途中の行があるか。閉じる途中の行は、並びが変わっても閉じ終えるまで前の縦の位置に描かれ、本来の位置に穴が開く。
    /// UIKitはこの動きをレイヤーの`animationKeys`に出さないので、描かれている位置と本来の位置の横のずれで見分ける。
    private var isRowClosingSwipe: Bool {
        collectionView.visibleCells.contains { cell in
            guard let shown = cell.layer.presentation() else { return false }
            return abs(shown.position.x - cell.layer.position.x) > 0.001
        }
    }

    /// スワイプのボタンを閉じ終えたら、溜めていた並びを反映する。
    private func waitForSwipeToClose() {
        guard swipeCloseTicker == nil else { return }
        let ticker = FrameTicker(source: frameSource) { [weak self] _ in
            guard let self else { return false }
            guard isRowClosingSwipe else {
                swipeCloseTicker = nil
                applyHeldEntries()
                return false
            }
            return true
        }
        swipeCloseTicker = ticker
        ticker.start()
    }

    /// スクロールの操作が終わったことを知らせる。溜めていた新着の挿入と、既読の位置の保存はここから始まる。
    /// 投稿を選んでいる間は知らせず、選び終えたときに知らせる。選んでいる間に新着が入ると、押そうとした行がずれるため。
    func reportInteractionSettled() {
        guard !isSelectingPosts else { return }
        onInteractionSettle?()
    }

    /// `setUnreadCount`を呼んだ回数。新着ボタンを描き直す前の並べ直しの中から呼ばれたかを見分ける。
    private var unreadCountUpdates = 0

    /// 既読より新しい投稿の数。0なら新着ボタンを隠す。
    /// - Parameter isLowerBound: 未読の区間に読み込んでいない投稿があり、実際はもっと多い。
    func setUnreadCount(_ count: Int, isLowerBound: Bool = false) {
        unreadCount = count
        unreadCountUpdates += 1
        let update = unreadCountUpdates
        // 通知のタブのバッジと同じく、読み込んでいない分があるときは「+」を付ける。
        let title = isLowerBound ? "\(count)+" : "\(count)"
        newArrivalsButton.accessibilityLabel = TimelineScreenTexts.newArrivals(count: count, isLowerBound: isLowerBound)
        if newArrivalsButton.configuration?.title != title || newArrivalsButtonShowsArrow != newArrivalsButtonWantsArrow {
            // 桁が変わると幅が変わるため、出ている間は前後のカプセルをクロスフェードする。幅を伸ばすと、伸びる途中で件数の文字が切れるため。
            // 「↑」の有無も同じく幅を変えるので、同じクロスフェードで入れ替える。続けて2回入れ替えると、幅が2段に変わって見えるため。
            if newArrivalsButtonShown, view.window != nil {
                // 待っている並べ直しは、クロスフェードの前に済ませる。中で済ませると、ボタンと関係のない行やメディアまで動きに乗るため。
                view.layoutIfNeeded()
                // 並べ直しでスクロール位置が補正されて既読が進むと、その中から新しい件数で呼ばれ、表示を済ませている。古い件数で上書きしない。
                guard update == unreadCountUpdates else { return }
                UIView.transition(with: newArrivalsButton, duration: newArrivalsButtonDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.newArrivalsButton.configuration?.title = title
                    self.setNewArrivalsButtonShowsArrow(self.newArrivalsButtonWantsArrow)
                    self.view.layoutIfNeeded()
                }
            } else {
                newArrivalsButton.configuration?.title = title
                updateNewArrivalsButtonArrow()
            }
        }
        updateNewArrivalsButtonVisibility()
    }

    /// 最上部にいる間は「↑」を外し、件数だけを出す。ウィンドウが前面にない間に追従した新着は、未読のまま画面に並び、上には何もないため。
    /// 件数は既読位置より新しい投稿の数のままにする。ほかの端末と同期する未読の数と揃えるため。
    /// 矢印の有無で幅が変わるため、件数の桁が変わるときと同じく、出ている間は前後のカプセルをクロスフェードする。
    /// 消えていく途中は変えず、次に出すときに合わせる。消えきる前に幅が詰まるのが見えるため。
    private func updateNewArrivalsButtonArrow() {
        let showsArrow = newArrivalsButtonWantsArrow
        guard newArrivalsButtonShowsArrow != showsArrow else { return }
        if newArrivalsButtonShown, view.window != nil {
            UIView.transition(with: newArrivalsButton, duration: newArrivalsButtonDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.setNewArrivalsButtonShowsArrow(showsArrow)
                self.view.layoutIfNeeded()
            }
        } else if newArrivalsButton.isHidden || view.window == nil {
            setNewArrivalsButtonShowsArrow(showsArrow)
        }
    }

    /// 最上部へ戻っている間は、行き先が最上部なので「↑」を外したままにする。新着に追従するときは、足した行の高さぶん下から戻るため、
    /// 途中の位置で決めると、件数を変えるだけのところで「↑」を出して外す2回の入れ替えが見えるため。
    private var newArrivalsButtonWantsArrow: Bool {
        !isAtTop && !isScrollingToTop
    }

    private func setNewArrivalsButtonShowsArrow(_ showsArrow: Bool) {
        newArrivalsButtonShowsArrow = showsArrow
        newArrivalsButton.configuration?.image = showsArrow ? UIImage(systemName: "arrow.up") : nil
    }

    private var newArrivalsButtonDuration: TimeInterval {
        tuning.value(of: TuningCatalog.newArrivalsButtonDuration)
    }

    /// 使う人の操作で最上部へ動かしている間は隠す。
    /// 新着に追従して最上部へ動かしている間は、出し入れを変えない。隠れていれば、新着が画面に入るまでの間だけ出てしまうため隠したままにし、
    /// 出ていれば（ウィンドウが前面にない間など、追従した新着が未読に残るとき）、件数が変わるだけなので、消して出し直さない。
    /// 出し入れは濃さで動かす。消え終えてから隠すので、消える途中にまた出すときは、見えている濃さから戻す。
    private func updateNewArrivalsButtonVisibility() {
        let hidesWhileScrolling = isScrollingToTop && (isScrollingToNewestByUser || !newArrivalsButtonShown)
        let isShown = unreadCount > 0 && !hidesWhileScrolling
        guard newArrivalsButtonShown != isShown else { return }
        // 消えていく途中に見送った「↑」の入れ替えを、出す前に済ませる。
        if isShown, newArrivalsButton.isHidden {
            setNewArrivalsButtonShowsArrow(newArrivalsButtonWantsArrow)
        }
        newArrivalsButtonShown = isShown
        let button = newArrivalsButton
        button.isUserInteractionEnabled = isShown
        if isShown {
            updateNewArrivalsButtonArrow()
        }
        guard view.window != nil else {
            button.alpha = isShown ? 1 : 0
            button.isHidden = !isShown
            return
        }
        if isShown, button.isHidden {
            button.alpha = 0
            button.isHidden = false
        }
        newArrivalsButtonGeneration += 1
        let generation = newArrivalsButtonGeneration
        UIView.animateSpring(duration: newArrivalsButtonDuration, in: button) {
            button.alpha = isShown ? 1 : 0
        } completion: {
            guard generation == self.newArrivalsButtonGeneration, !self.newArrivalsButtonShown else { return }
            button.isHidden = true
        }
    }

    // MARK: アプリ内通知

    /// 押し直せば済む失敗を、チップの列に数秒出す。決まりはdocs/notices.mdの「置き場所」にある。
    func showNotice(_ notice: Notice) {
        showNotice(notice, duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    /// 数秒で消えるアプリ内通知を出す。
    func showNotice(_ notice: Notice, duration: TimeInterval) {
        notices?.showTransient(notice, duration: duration)
    }

    /// ストリーミングにつながらない状態が続いていることを、タイトルの下に控えめに出す。題の下に添える文字があれば、その後ろに並べる。
    func setOutageNotice(_ isShown: Bool) {
        navigationItem.subtitle = texts.subtitle(showsStreamingOutage: isShown)
    }

    func setContentState(_ state: ContentState) {
        contentState = state
        setNeedsUpdateContentUnavailableConfiguration()
    }

    func setFooterState(_ state: FooterState) {
        footerState = state
        if let footer = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter).first as? TimelineFooterView {
            configure(footer)
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard headerView == nil, dataSource.snapshot().numberOfItems == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = contentUnavailableConfiguration(for: contentState)
    }

    /// 投稿が1件もないときに、タイムラインの全面に出す表示。
    func contentUnavailableConfiguration(for state: ContentState) -> UIContentUnavailableConfiguration {
        switch state {
        case .loading:
            return UIContentUnavailableConfiguration.loading()
        case .loaded:
            return emptyConfiguration(text: texts.empty, secondaryText: texts.emptyDetail, buttonTitle: TimelineScreenTexts.reload)
        case .regenerating:
            return emptyConfiguration(
                text: TimelineScreenTexts.regeneratingTitle,
                secondaryText: TimelineScreenTexts.regeneratingDetail,
                buttonTitle: TimelineScreenTexts.reload
            )
        case .failed(let message):
            var configuration = emptyConfiguration(text: TimelineScreenTexts.loadFailure, secondaryText: nil, buttonTitle: TimelineScreenTexts.retry)
            configuration.secondaryAttributedText = message.attributedText(textStyle: .body)
            return configuration
        case .unavailable:
            // 読み直しても読めないので、再試行のボタンは置かない。
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = texts.unavailable
            return configuration
        }
    }

    /// 投稿がない状態から読み込み直せるよう、どの表示にも再試行ボタンを置く。
    private func emptyConfiguration(text: String, secondaryText: String?, buttonTitle: String) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.button = .borderedTinted()
        configuration.button.title = buttonTitle
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onRetry?() }
        return configuration
    }

    /// 違和感レポートに含める、スクロール位置と表示中の投稿の状態。
    func stateDump() -> String {
        let visibleIDs = collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }.map(Self.label)
        let anchor = currentAnchor()
        return """
        items: \(dataSource.snapshot().numberOfItems)
        contentOffset.y: \(collectionView.contentOffset.y)
        contentSize.height: \(collectionView.contentSize.height)
        adjustedContentInset.top: \(collectionView.adjustedContentInset.top)
        contentInset.top: \(collectionView.contentInset.top) refreshing: \(refreshControl.isRefreshing) refreshFrame: \(refreshControl.frame)
        visibleItems: \(visibleIDs.joined(separator: ", "))
        anchor: \(anchor.map { "\(Self.label($0.id)) distanceFromVisibleTop=\($0.distanceFromVisibleTop)" } ?? "nil")
        lastScrollDirection: \(lastScrollDirection.map { "\($0)" } ?? "nil")
        contentState: \(contentState.dumpLabel)
        footerState: \(footerState.dumpLabel)
        isAtTop: \(isAtTop)
        unreadCount: \(unreadCount)
        loadingGaps: \(loadingGapIDs.sorted().joined(separator: ", "))
        failedGaps: \(gapFailures.keys.sorted().joined(separator: ", "))
        showingMenu: \(isShowingMenu) heldEntries: \(heldEntries.map { "\($0.entries.count)" } ?? "nil")
        """
    }

    /// ログと状態ダンプで要素を示す表記。投稿はID、ギャップは`gap-`で始まるID。
    private static func label(_ id: ItemID) -> String {
        switch id {
        case .status(let id): id
        case .gap(let id): id
        case .notification(let id): "notification-\(id)"
        case .pinned(let id): "pinned-\(id)"
        case .unreadable(let id): "unreadable-\(id)"
        case .account(let id): "account-\(id)"
        case .notificationRequest(let id): "notificationRequest-\(id)"
        case .search(let id): "search-\(SearchRow.dumpLabel(ofID: id))"
        }
    }

    /// 表示している投稿のID。上から順。ギャップは含めない。
    var displayedStatusIDs: [Status.ID] {
        dataSource.snapshot().itemIdentifiers.compactMap { id in
            if case .status(let statusID) = id { statusID } else { nil }
        }
    }

    /// 表示している要素のID。上から順。
    var displayedItemIDs: [ItemID] {
        dataSource.snapshot().itemIdentifiers
    }

    func itemIdentifier(at indexPath: IndexPath) -> ItemID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func entry(for id: ItemID) -> TimelineEntry? {
        entries[id]
    }

    /// タイムラインの位置にある要素。
    func itemID(at indexPath: IndexPath) -> ItemID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    /// 違和感レポートの操作の記録に残す、画面の名前。
    var screenName: String {
        texts.dumpName
    }

    /// タイムラインの行にいる、そのIDのアカウント。いなければnil。
    func account(withID id: String) -> Account? {
        entries.values.account(withID: id)
    }

    /// タイムラインの投稿のメンションのうち、リンク先が`url`の人。本文のメンションのリンクにはIDがないため、投稿のメンションから引く。
    func mention(withURL url: URL) -> Mention? {
        entries.values.mention(withURL: url)
    }

    /// 要素の行。画面の外にあればnil。
    func cell(for id: ItemID) -> UICollectionViewCell? {
        dataSource.indexPath(for: id).flatMap(collectionView.cellForItem(at:))
    }

    private func makeNewArrivalsButton() -> UIButton {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.up")
        // ボタンが件数の文字に合わせて決める矢印の大きさを、一段小さくする。既定のままでは件数より大きく見えるため。
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
        configuration.imagePadding = 1
        configuration.buttonSize = .small
        let button = TintFollowingButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            // 慣性で動いている途中なら、それまでのスクロールが先に記録されるよう、動かしてから記録する。
            scrollToNewest()
            UserAction.tapNewArrivals(screen: texts.dumpName).record()
        })
        // Macでウインドウが前面にない間は、色付きの下地が淡い灰色に変わる。白い文字のままでは読めないため、文字を下地に合わせる。
        // 色は動的な色で渡さず、前面かどうかが変わったところで決め直す。Macでは、ボタンが色を解決するtintの知らせが、
        // 前面かどうかの変化より先に届くため、動的な色では1回前の状態の色が残り、青い下地に黒い文字になる（issue #1と同じずれ）。
        button.configurationUpdateHandler = { button in
            (button as? TintFollowingButton)?.appliesGlassAccent()
            if button.traitCollection.activeAppearance == .inactive {
                button.configuration?.baseForegroundColor = .label
            }
        }
        button.registerForTraitChanges([UITraitActiveAppearance.self]) { (button: UIButton, _) in
            button.setNeedsUpdateConfiguration()
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.alpha = 0
        return button
    }

    /// 投稿がタイムラインにあれば、覆われていない表示領域の下端に来るまでスクロールする。返信先のラベルから、書いている入力欄のすぐ上に返信先を出すために使う。
    /// 同じ投稿が元の投稿とブースト、通知などで何か所にも並ぶことがあるため、まず返信を選んだ要素そのもの（ブーストならブーストのID）を探し、
    /// なければ中身が同じ投稿（`displayedID`、ブーストなら元の投稿のID）を探す。タイムラインになければ動かさずにfalseを返す。
    @discardableResult
    func scrollToStatus(_ statusID: Status.ID, displayedID: Status.ID? = nil, at position: UICollectionView.ScrollPosition = .bottom, animated: Bool = true) -> Bool {
        let displayedID = displayedID ?? statusID
        let ids = displayedItemIDs
        // 固定投稿は、同じ投稿が下のタイムラインにも並ぶことがあり、IDでは見分けられない。上にある固定投稿の方へ移る。
        let chosen = ids.first { entries[$0]?.targetStatus?.id == statusID }
        let found = chosen ?? ids.first { entries[$0]?.targetStatus?.displayed.id == displayedID }
        guard let found, let indexPath = dataSource.indexPath(for: found) else { return false }
        if animated {
            // 最上部へ動かしている途中なら、速さを持ち越して行き先だけ替える。
            startSpringScroll(
                to: .item(found, position),
                duration: tuning.value(of: TuningCatalog.scrollToStatusDuration),
                bounce: tuning.value(of: TuningCatalog.scrollToStatusBounce)
            )
        } else {
            // 最上部へ動かしている途中なら、それをやめる。続けると、投稿へ動かした位置と取り合う。
            stopSpringScroll()
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
        }
        return true
    }

    /// アプリ内のSafariを全画面に広げて、タイムラインを覆っている。
    private var isCoveredByInAppBrowser = false

    /// アプリ内のSafariは後ろにタイムラインを残したまま全画面に広がるため、広げている間はタイムラインの投稿を見たと報告しない。
    /// 中くらいの高さに戻したら、そこで見えている投稿を報告し直す。
    func setCoveredByInAppBrowser(_ covered: Bool) {
        guard isCoveredByInAppBrowser != covered else { return }
        isCoveredByInAppBrowser = covered
        if covered {
            onVisibleUnsettledStatusesChange?([])
        } else {
            reportVisibleItems()
        }
    }

    /// 表示中の要素を報告し直すかを決めるために最後に見た、タイムラインの下端の余白。投稿欄のカプセルなどが覆う分も入る。
    private var reportedBottomInset: CGFloat = 0

    /// タイムラインを置いたウィンドウが前面にない。Macでほかのアプリを使っている間や、iPhoneでコントロールセンターを開いている間など。
    private(set) var isWindowInactive = false

    /// ウィンドウが前面にない間は、タイムラインが画面に出ていても見ているとは限らないため、使う人がスクロールしたときのほかは、投稿を見たと報告しない。
    /// 既読位置はほかの端末と同期するため、前面にないMacで見たことにすると、iPhoneで開いたときに読んでいない新着まで既読になる。
    /// Macでは前面にないウィンドウもスクロールでき、スクロールしたなら見ているので報告する。前面に戻ったら、そこで見えている投稿を報告し直す。
    func setWindowInactive(_ inactive: Bool) {
        guard isWindowInactive != inactive else { return }
        isWindowInactive = inactive
        logger.info("window inactive=\(inactive, privacy: .public)")
        if inactive {
            onVisibleUnsettledStatusesChange?([])
        } else {
            reportVisibleItems()
        }
    }

    /// スレッドでは、押した投稿を表示領域の上端まで上げられるだけの余白を、タイムラインの下に足す。
    /// 投稿欄のカプセルなどが下端を覆う分は、ナビゲーションがsafe areaに入れるので、ここでは足さない。
    /// 投稿を選んでいる間は、投稿欄がカプセルを隠して覆う高さを0と知らせるので、ここで分けない。
    /// スレッドでは並べ直すたびに測り直すので、アクションバーの開閉、注意書きの開閉、長い本文の展開などの経路ごとには呼ばない。
    /// 並べ終えたあとに呼ぶときは、`layingOut`をfalseにして、並べ直さずに測る。
    private func updateBottomInset(layingOut: Bool = true) {
        guard isViewLoaded else { return }
        let fill = threadFocusBottomFill(layingOut: layingOut)
        guard collectionView.contentInset.bottom != fill else { return }
        collectionView.contentInset.bottom = fill
    }

    /// 押した投稿から下の行が表示領域の高さに足りない分。足りないと、押した投稿を押した位置に置いたままにできず、タイムラインが端まで戻ってしまうため。
    private func threadFocusBottomFill(layingOut: Bool) -> CGFloat {
        guard let threadFocusID, let indexPath = dataSource.indexPath(for: .status(threadFocusID)) else { return 0 }
        if layingOut {
            collectionView.layoutIfNeeded()
        }
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return 0 }
        let visibleHeight = collectionView.bounds.height - collectionView.adjustedContentInset.top - view.safeAreaInsets.bottom
        return max(visibleHeight - (collectionView.contentSize.height - frame.minY), 0)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateBottomInset()
    }

    /// 新着ボタン、タブの選び直し、ステータスバーのタップで、最上部へ戻る。
    func scrollToNewest() {
        // 慣性で動いている途中にこちらで動かすと、止まりの通知が来ないため、ここまでのスクロールを記録する。
        recordScroll()
        isScrollingToNewestByUser = true
        scrollToTop(
            duration: tuning.value(of: TuningCatalog.scrollToTopDuration),
            bounce: tuning.value(of: TuningCatalog.scrollToTopBounce)
        )
    }

    /// スプリングで動かす行き先。
    private enum SpringScrollDestination: Equatable {
        case top
        /// 行が表示領域の`position`に来る位置。
        case item(ItemID, UICollectionView.ScrollPosition)
    }

    /// 最上部へスプリングで動かす。
    private func scrollToTop(duration: TimeInterval, bounce: Double) {
        startSpringScroll(to: .top, duration: duration, bounce: bounce)
    }

    /// 行き先へスプリングで動かす。UIKitのスクロールのアニメーションは時間も曲線も変えられないため、毎フレーム位置を置く。
    ///
    /// まだ表示していないセルは見積もりの高さで並び、表示されたときに実寸へ変わる。上のセルが変わるとUICollectionViewがそのぶん位置を補正し、
    /// 行き先の行の位置も変わる。動いている途中に新着を足したときも、読んでいる位置を保つためにずらす。
    /// 毎フレーム行き先を測り直し、ずれた位置から速さを持ち越して向かうため、中身は飛ばず、止まり直しもしない。
    /// UIKitのアニメーションは動き始めに見積もりで行き先を決めるため、途中でコマが飛ぶと、行き先の行が画面の外に残ることがある。
    /// すでに動かしていれば、速さを持ち越して行き先と時間とバウンスだけ替える。動いている途中に指が触れたら止め、指の操作に任せる。
    private func startSpringScroll(to destination: SpringScrollDestination, duration: TimeInterval, bounce: Double) {
        springScrollDestination = destination
        springScroll = SpringScroll(duration: duration, bounce: bounce, velocity: springScroll?.velocity ?? 0)
        if springScrollTicker == nil {
            // 慣性で動いている途中なら止める。止めないと、慣性で動かす位置と取り合う。
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            // 動いている途中にこの画面が閉じられて解放されたら、続けないと返して止めさせる。
            let ticker = FrameTicker(source: frameSource) { [weak self] elapsed in
                guard let self else { return false }
                stepSpringScroll(elapsed: elapsed)
                return springScrollTicker != nil
            }
            springScrollTicker = ticker
            springScrollInterruption.isEnabled = true
            ticker.start()
        }
        updateNewArrivalsButtonVisibility()
    }

    /// 最上部にいるときのスクロール位置。
    private var topOffset: CGFloat {
        -collectionView.adjustedContentInset.top
    }

    private func stepSpringScroll(elapsed: CFTimeInterval) {
        // 指が触れた時点で止める。ドラッグが始まるのを待つと、触れてから指が動くまでの間も動き続け、指の下で中身がずれる。
        // 行き先の行がタイムラインからなくなったときも止める。
        guard !collectionView.isTracking, var scroll = springScroll, let target = springScrollTarget() else {
            stopSpringScroll()
            return
        }
        let next = scroll.step(from: collectionView.contentOffset.y, toward: target, by: elapsed)
        springScroll = scroll
        guard !scroll.isSettled(at: next, target: target) else {
            didFinishSpringScroll(at: target)
            return
        }
        collectionView.contentOffset.y = next
    }

    /// 行き先のスクロール位置。行き先の行がなければnil。セルが実寸へ変わると行の位置も変わるため、毎フレーム測り直す。
    private func springScrollTarget() -> CGFloat? {
        guard case .item(let id, let position) = springScrollDestination else { return topOffset }
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return nil }
        let inset = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - inset.top - inset.bottom
        let offset = switch position {
        case .top: frame.minY - inset.top
        case .centeredVertically: frame.midY - inset.top - visibleHeight / 2
        default: frame.maxY - inset.top - visibleHeight
        }
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, topOffset)
        return min(max(offset, topOffset), maxOffset)
    }

    /// 落ち着いたら行き先にそろえる。新着ボタンは、見えた投稿を既読にしてから出し直す。先に出すと、既読になるまでの一瞬だけ出てしまう。
    private func didFinishSpringScroll(at target: CGFloat) {
        endSpringScroll()
        collectionView.contentOffset.y = target
        reportVisibleItemsAfterLayout()
        updateNewArrivalsButtonVisibility()
        reportInteractionSettled()
    }

    /// 途中で止めたら、止まった位置で「↑」を決め直す。最上部へ戻る間は外しているため。
    private func stopSpringScroll() {
        endSpringScroll()
        updateNewArrivalsButtonVisibility()
        updateNewArrivalsButtonArrow()
    }

    private func endSpringScroll() {
        springScrollTicker?.stop()
        springScrollTicker = nil
        springScroll = nil
        isScrollingToNewestByUser = false
        // 触れて止めたときは、指が離れるまで有効のままにする。途中で無効にすると、止めた指のタッチが中身に渡る。
        if !springScrollInterruption.isHolding {
            springScrollInterruption.isEnabled = false
        }
    }

    /// 最上部へスプリングで動かしている。
    var isScrollingToTop: Bool {
        springScrollTicker != nil && springScrollDestination == .top
    }

    private func makeSpringScrollInterruption() -> TouchHoldGestureRecognizer {
        let recognizer = TouchHoldGestureRecognizer()
        recognizer.isEnabled = false
        recognizer.delegate = self
        recognizer.onHold = { [weak self] in self?.stopSpringScroll() }
        recognizer.onRelease = { [weak self] in
            guard let self, springScrollTicker == nil else { return }
            springScrollInterruption.isEnabled = false
            // 止めた指をドラッグせずに離すと、スクロールの止まりの知らせが来ないので、ここで知らせる。ドラッグしたなら、その止まりの知らせに任せる。
            guard !isUserScrolling else { return }
            reportInteractionSettled()
        }
        return recognizer
    }

    /// 表示領域に近づいたギャップを報告する。どこまで近づいたら、どちらの端から読ませるかは`TimelineLoadTrigger`が決める。
    private func reportApproachingGaps() {
        guard let onGapApproach, !isRestoringAnchor, !isScrollingToTop, !gapIDs.isEmpty else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let gaps = gapIDs.filter { !loadingGapIDs.contains($0) }.compactMap { gapID -> (id: String, frame: CGRect)? in
            guard let indexPath = dataSource.indexPath(for: .gap(gapID)),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return nil }
            return (gapID, frame)
        }
        let isScrolling = collectionView.isTracking || collectionView.isDecelerating
        for gap in TimelineLoadTrigger.approachingGaps(gaps, in: visibleRect, scrollDirection: isScrolling ? lastScrollDirection : nil, tuning: tuning) {
            onGapApproach(gap.id, gap.direction)
        }
    }

    /// スクロールが止まったときに、レイアウトを確定させてから表示中の要素を報告し直す。
    /// スクロールの通知の時点では表示中のセルが前のフレームのままで、遠くから一気に動くと、
    /// 最後の通知に止まった位置の要素が入らないため。
    private func reportVisibleItemsAfterLayout(byUser: Bool = false) {
        collectionView.layoutIfNeeded()
        reportVisibleItems(byUser: byUser)
    }

    /// 表示中の投稿と通知を報告する。どの行を含めるかと、どんな間は報告しないかは`ReadVisibility`が決める。ナビゲーションバーの下に隠れている部分は数えない。
    /// レイアウト中に位置を戻している間は、行が仮の位置にあるので報告しない。
    func reportVisibleItems(byUser: Bool = false) {
        let isShown = viewIfLoaded?.window != nil && !isCoveredByMediaViewer && !isCoveredByInAppBrowser
        guard !isRestoringAnchor, ReadVisibility.shouldReport(isShown: isShown, isWindowActive: !isWindowInactive, byUser: byUser) else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let rows = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (id: ItemID, frame: CGRect)? in
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return (id, frame)
        }
        let ids = ReadVisibility.visibleIDs(of: rows, in: visibleRect)
        onVisibleStatusesChange?(ids.compactMap { id in
            if case .status(let statusID) = id { statusID } else { nil }
        })
        onVisibleNotificationsChange?(ids.compactMap { id in
            if case .notification(let notificationID) = id { notificationID } else { nil }
        })
        onVisibleUnsettledStatusesChange?(unsettledStatuses(among: ids))
        prefetchMediaIfSettled(among: ids)
    }

    /// スクロールが止まっていれば、`ids`の行に出ている画像を先読みする（docs/image-loading.mdの「ビューアで開く画像の先読み」）。
    /// 動いている間は止め、流し見で通り過ぎた投稿を読まない。止まったときに差し替え、画面から外れた画像の読み込みを止める。
    private func prefetchMediaIfSettled(among ids: [ItemID]) {
        guard let mediaPrefetcher else { return }
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating, springScroll == nil else {
            mediaPrefetcher.prefetch([])
            return
        }
        let attachments = ids.flatMap { id -> [MediaAttachment] in
            guard let indexPath = dataSource.indexPath(for: id), let contentView = collectionView.cellForItem(at: indexPath)?.contentView else { return [] }
            let post = contentView as? PostContentView
            let grids = [post?.mediaGrid, post?.embedMediaGrid, (contentView as? NotificationContentView)?.mediaGrid]
            return grids.compactMap { $0?.content?.attachments }.flatMap { $0 }
        }
        mediaPrefetcher.prefetch(attachments)
    }

    /// `ids`の行のうち、取り直す理由のある投稿。理由は、その行に出している部品のものだけを数える。
    /// 通知でカードを出さない行などを除くため、組み立てた中身で見分ける。
    private func unsettledStatuses(among ids: [ItemID]) -> [Status] {
        ids.compactMap { id -> Status? in
            guard let indexPath = dataSource.indexPath(for: id),
                  let configuration = collectionView.cellForItem(at: indexPath)?.contentConfiguration as? PostContentConfiguration,
                  let status = status(for: id)?.displayed
            else { return nil }
            var shown: StatusRefreshNeeds = []
            if configuration.card != nil { shown.insert(.linkCard) }
            if configuration.embed != nil { shown.insert(.pendingQuote) }
            guard !shown.isEmpty else { return nil }
            // スクロールのたびに呼ばれるので、カードは行を組み立てたときに作ったものを使う。
            return StatusRefreshNeeds(status, card: configuration.card?.card).isDisjoint(with: shown) ? nil : status
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.footerMode = isAppearancePreview ? .none : .supplementary
        configuration.headerMode = headerView == nil ? .none : .supplementary
        // ヘッダー画像をナビゲーションバーのすぐ下から置く。
        configuration.headerTopPadding = 0
        // 線で下の行とつながっている行も、区切り線を出さない。つながった行を1つの会話として見せるため。
        configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
            guard let self, let id = self.dataSource.itemIdentifier(for: indexPath) else { return separator }
            // 線は本文の左端から引く。アイコンの下を空けるときは、アイコンの列に線を入れない。決まりはdocs/post-header-layout.mdにある。
            var separator = self.listStyle.separator(
                separator,
                isFirst: indexPath.item == 0,
                isLast: self.dataSource.itemIdentifier(for: IndexPath(item: indexPath.item + 1, section: indexPath.section)) == nil,
                leading: self.entries[id].map { self.separatorLeadingInset(for: $0) },
                joinsNext: self.replyConnections[id]?.below == true
            )
            guard self.settings.appearance.showsSeparators else {
                self.drawSeparatorUnderReactionGlow(&separator, id: id, at: indexPath)
                return separator
            }
            // 検索の結果の見出しは、連絡先アプリの見出しと同じく、上に線を引かず、下に左右の余白を空けた線を引く。
            // 見出しの上は空きで区切るため、直前の行の下の線も消す。
            let headingInsets = NSDirectionalEdgeInsets(top: 0, leading: self.settings.rowMargins.leading, bottom: 0, trailing: self.settings.rowMargins.trailing)
            if self.isSearchHeading(id) {
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorInsets = headingInsets
            }
            if indexPath.item > 0, let previous = self.dataSource.itemIdentifier(for: IndexPath(item: indexPath.item - 1, section: indexPath.section)), self.isSearchHeading(previous) {
                separator.topSeparatorInsets = headingInsets
            }
            if let next = self.dataSource.itemIdentifier(for: IndexPath(item: indexPath.item + 1, section: indexPath.section)), self.isSearchHeading(next) {
                separator.bottomSeparatorVisibility = .hidden
            }
            self.drawSeparatorUnderReactionGlow(&separator, id: id, at: indexPath)
            return separator
        }
        // 保留中の通知の行は、右へスワイプで受け入れ、左へスワイプで無視する。決まりはdocs/notification-filter.mdにある。
        // 投稿の行は、設定で割り当てた項目を出す。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard self?.isAppearancePreview == false else { return nil }
            return self?.notificationRequestSwipe(at: indexPath, .accept) ?? self?.postSwipe(at: indexPath, side: .leading)
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard self?.isAppearancePreview == false else { return nil }
            return self?.notificationRequestSwipe(at: indexPath, .dismiss) ?? self?.accountRemovalSwipe(at: indexPath) ?? self?.recentSearchSwipe(at: indexPath)
                ?? self?.postSwipe(at: indexPath, side: .trailing)
        }
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // plainのリストはフッターを表示範囲の下端に貼り付ける。貼り付いたフッターは、中身がなくてもタブバーのすぐ上を覆ってタップを吸うため、タイムラインの末尾に置く。
            for item in section.boundarySupplementaryItems {
                item.pinToVisibleBounds = false
            }
            return section
        }
    }

    /// 保留中の通知の行のスワイプ。ほかの行ではnil。行を消すのは送れてからなので、スワイプした行はいったん戻す。
    private func notificationRequestSwipe(at indexPath: IndexPath, _ decision: NotificationRequestDecision) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .notificationRequest(let request) = entries[id], let onDecision = onNotificationRequestDecision else { return nil }
        let action = switch decision {
        case .accept:
            UIContextualAction(style: .normal, title: decision.title) { _, _, completion in
                onDecision(.accept, request)
                completion(false)
            }
        case .dismiss:
            UIContextualAction(style: .destructive, title: decision.title) { _, _, completion in
                onDecision(.dismiss, request)
                completion(false)
            }
        }
        switch decision {
        case .accept:
            action.image = UIImage(systemName: "checkmark")
            action.backgroundColor = .systemGreen
        case .dismiss:
            action.image = UIImage(systemName: "xmark")
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// 人の行を左へスワイプして外す。`onRemoveAccount`を渡した画面でだけ出す。行を消すのは外せてからなので、スワイプした行はいったん戻す。
    private func accountRemovalSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .account(let account) = entries[id], let onRemoveAccount else { return nil }
        let action = UIContextualAction(style: .destructive, title: accountRemoval.title) { _, _, completion in
            onRemoveAccount(account)
            completion(false)
        }
        action.image = UIImage(systemName: accountRemoval.symbolName)
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// 検索の結果と候補の見出しの行か。
    private func isSearchHeading(_ id: ItemID) -> Bool {
        if case .search(let row) = entries[id] { row.isHeading } else { false }
    }

    /// 最近の検索の行のスワイプ。ほかの行ではnil。
    private func recentSearchSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .search(.recent(let query)) = entries[id], let onRemove = onRemoveRecentSearch else { return nil }
        let action = UIContextualAction(style: .destructive, title: SearchScreenTexts.removeRecent) { _, _, completion in
            onRemove(query)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// 光っている投稿の下の区切り線は、UIKitの線の代わりに、光の下に敷く線で引く。UIKitの線は光の手前に描かれ、光源に重なると灰色に濁るため。決まりはdocs/reaction-glow.mdにある。
    /// 取り消した光が消えていく間も、光の下に敷いた線のままにする。
    private func drawSeparatorUnderReactionGlow(_ separator: inout UIListSeparatorConfiguration, id: ItemID, at indexPath: IndexPath) {
        let content = collectionView.cellForItem(at: indexPath)?.contentView as? any ReactionGlowHosting
        let shown = status(for: id)?.displayed
        let isLit = shown?.favourited == true || shown?.reblogged == true || content?.isShowingReactionGlow == true
        let leading = isLit && separator.bottomSeparatorVisibility != .hidden ? separator.bottomSeparatorInsets.leading : nil
        reactionGlowSeparatorLeadings[id] = leading
        content?.setReactionGlowSeparator(leading: leading)
        if isLit {
            separator.bottomSeparatorVisibility = .hidden
        }
    }

    /// 区切り線を引き始める、行の左端からの長さ。行の本文の左端にする。
    func separatorLeadingInset(for entry: TimelineEntry) -> CGFloat {
        let textColumn = settings.textColumnLeading
        switch entry {
        case .status(let status), .pinned(let status):
            return settings.postSeparatorLeading(appearance(for: status))
        case .notification(let notification):
            // メンションなどは投稿の行として描くので、投稿と同じ。ほかの通知の行は、アイコンの列の右に文字を置く。
            return notification.layout == .post && notification.status != nil ? settings.postSeparatorLeading : textColumn
        case .account, .notificationRequest:
            return textColumn
        case .search:
            // システムのリストの部品で組む行。投稿や人の行と揃えるため、文字の列から引く。
            return textColumn
        case .gap, .unreadable:
            // システムのリストの部品で組む行。任せると、すき間の行は行の余白から、読めなかった投稿の行は記号の右の文字から引き、右端も手前で止まって投稿の行の線と揃わないため、文字の列から引く。
            return textColumn
        }
    }

    /// クラッシュした投稿の行を、読めない行に差し替える。決まりはdocs/crash-quarantine.mdにある。
    private func quarantined(_ entry: TimelineEntry) -> TimelineEntry {
        guard let statusID = entry.quarantinableStatusID, crashGuard.isQuarantined(statusID) else { return entry }
        if let url = entry.targetStatus?.displayed.url {
            notices?.quarantinedPageURLs[statusID] = url
        }
        return .unreadable(UnreadableItem(id: statusID, url: nil, isCrashQuarantined: true))
    }

    private func configure(_ cell: TimelineCell, for entry: TimelineEntry, id: ItemID) {
        cell.discardShrinkSnapshot()
        switch entry {
        case .status(let status):
            cell.contentConfiguration = contentConfiguration(for: status, itemID: id, base: cell.defaultContentConfiguration())
        case .pinned(let status):
            cell.contentConfiguration = contentConfiguration(for: status, isPinned: true, itemID: id, base: cell.defaultContentConfiguration())
        case .gap(let gap):
            cell.contentConfiguration = gapContentConfiguration(
                isLoading: loadingGapIDs.contains(gap.id),
                failure: gapFailures[gap.id],
                base: cell.defaultContentConfiguration()
            )
        case .notification(let notification):
            cell.contentConfiguration = contentConfiguration(for: notification, itemID: id, base: cell.defaultContentConfiguration())
        case .unreadable(let item):
            cell.contentConfiguration = unreadableContentConfiguration(for: item, base: cell.defaultContentConfiguration())
        case .account(let account):
            cell.contentConfiguration = accountConfiguration(for: account, base: cell.defaultContentConfiguration())
        case .notificationRequest(let request):
            cell.contentConfiguration = notificationRequestConfiguration(for: request, base: cell.defaultContentConfiguration())
        case .search(let row):
            cell.contentConfiguration = searchRowConfiguration(for: row, base: cell.defaultContentConfiguration())
            if row == .recentsHeading {
                cell.accessories = [.customView(configuration: .init(customView: removeAllRecentSearchesButton(), placement: .trailing()))]
            }
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, ItemID> {
        let registration = UICollectionView.CellRegistration<TimelineCell, ItemID> { [weak self] cell, _, id in
            guard let self, let entry = self.entries[id] else { return }
            // 別の行を出し始めたセルは、中身を動きの外で並べる。Macでウインドウの幅を変えたときのように、タイムラインが動きの中で並べ直すと、
            // 初めて画面に入った行の写真やボタンまで動きに乗り、大きさ0の左上から滑ってきて見えるため。
            // 同じ行の描き直し（リンクカードが届いたときなど）は、これまでどおり呼んだ側の動きに任せる。
            let startsNewRow = cell.itemID != id
            cell.itemID = id
            cell.crashGuard = self.crashGuard
            cell.crashMarkID = entry.quarantinableStatusID
            self.crashGuard.mark(cell.crashMarkID)
            #if DEBUG
            if cell.crashMarkID != nil { DebugFaults.crashIfRequestedOnRow() }
            #endif
            cell.tuning = self.tuning
            // 付属のボタンを置くのは最近の検索の見出しだけなので、ほかの行に使い回したセルに残さない。ふだんの行では触らない。
            if !cell.accessories.isEmpty {
                cell.accessories = []
            }
            FrameWork.measure("\(entry.rowKind.rawValue).configure") { self.configure(cell, for: entry, id: id) }
            (cell.contentView as? any ReactionGlowHosting)?.setReactionGlowSeparator(leading: self.reactionGlowSeparatorLeadings[id])
            cell.sizingTrace.row = entry.rowKind
            cell.updateSizingParts(from: cell.contentConfiguration)
            cell.setSelectionMark(self.selectionMark(for: id))
            if startsNewRow {
                UIView.performWithoutAnimation { cell.layoutIfNeeded() }
            }
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, _ in
            footer.onRetry = { self?.onRetry?() }
            self?.configure(footer)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<TimelineHeaderContainerView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] container, _, _ in
            container.host(self?.headerView)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, ItemID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return FrameWork.measure("header.dequeue") { collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath) }
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.main])
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        return dataSource
    }

    private func configure(_ footer: TimelineFooterView) {
        // ヘッダーのあるタイムラインでは、投稿がないことも全面の表示ではなくフッターで示す。ヘッダーのないタイムラインでは全面の表示が示すので、フッターには出さない。
        // データソースを作る途中でも呼ばれるため、データソースではなく表示中の要素から数える。
        let reachedEndText = entries.isEmpty ? (headerView == nil ? "" : texts.empty) : texts.reachedEnd
        footer.apply(footerState, reachedEndText: reachedEndText)
    }

    /// 読めなかった投稿や通知の行。読めなかったことを隠さず、開けるならブラウザで開けることを示す。
    func unreadableContentConfiguration(for item: UnreadableItem, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        content.image = UIImage(systemName: "exclamationmark.triangle")
        content.imageProperties.tintColor = .secondaryLabel
        content.text = texts.unreadable
        content.textProperties.color = .secondaryLabel
        content.secondaryText = TimelineScreenTexts.unreadableDetail(isCrashQuarantined: item.isCrashQuarantined, opensInBrowser: item.url != nil)
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    /// 検索の結果の、投稿と人のほかの行。決まりはdocs/search.mdにある。
    func searchRowConfiguration(for row: SearchRow, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        switch row {
        case .heading(let category):
            content = UIListContentConfiguration.header()
            content.text = category.title
        case .hashtag(let hashtag):
            content.image = UIImage(systemName: "number")
            content.imageProperties.tintColor = .secondaryLabel
            content.text = "#\(hashtag.name)"
            content.textProperties.numberOfLines = 1
        case .showAll:
            content.text = SearchScreenTexts.showAll
            content.textProperties.color = .tintColor
        case .failed(_, let failure):
            // 押すと読み込み直すため、押せることを色で示す。理由は下に小さく添える。
            content.text = TimelineScreenTexts.loadFailureTapToRetry
            content.textProperties.color = .tintColor
            content.secondaryAttributedText = failure.attributedText(textStyle: .footnote)
        case .action(let action):
            content.image = UIImage(systemName: action.symbolName)
            content.text = action.title
            content.textProperties.numberOfLines = 1
        case .recentsHeading:
            content = UIListContentConfiguration.header()
            content.text = SearchScreenTexts.recentsHeading
        case .recent(let query):
            content.image = UIImage(systemName: "clock.arrow.circlepath")
            content.imageProperties.tintColor = .secondaryLabel
            content.text = query
            content.textProperties.numberOfLines = 1
        }
        return content
    }

    /// 最近の検索の見出しに添える「消去」。
    private func removeAllRecentSearchesButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = SearchScreenTexts.clearRecents
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onRemoveAllRecentSearches?() })
    }

    /// - Parameter failure: 直近の読み込みに失敗した理由。読み込み中なら、読み込み中の表示を優先する。
    func gapContentConfiguration(isLoading: Bool, failure: ErrorPresentation? = nil, base: UIListContentConfiguration) -> UIListContentConfiguration {
        var content = base
        content.textProperties.alignment = .center
        if isLoading {
            content.text = TimelineScreenTexts.loading
            content.textProperties.color = .secondaryLabel
        } else if let failure {
            // 押すと読み込み直すため、押せることを色で示す。理由は下に小さく添える。
            content.text = TimelineScreenTexts.loadFailureTapToRetry
            content.textProperties.color = .tintColor
            content.secondaryAttributedText = failure.attributedText(textStyle: .footnote)
            content.secondaryTextProperties.alignment = .center
        } else {
            content.text = TimelineScreenTexts.loadGap
            content.textProperties.color = .tintColor
        }
        return content
    }

    /// 投稿のセルの中身を組み立てる。今のチューニングと設定を読むため、使うたびに作る。
    var postContentBuilder: PostContentBuilder {
        PostContentBuilder(tuning: tuning, renderSettings: listStyle.renderSettings, emojiImages: emojiImages, mediaImages: mediaImages, avatarImages: avatarImages, preparedBodies: bodyTextPreparer)
    }

    /// `status`の行を組むときの見た目の選択肢。スレッドで開いた投稿は、選んでいれば、表示しない設定にした部品もすべて出す（docs/appearance.md）。
    func appearance(for status: Status) -> AppearanceChoices {
        let appearance = settings.appearance
        guard appearance.revealsAllPartsInThread, let threadFocusID, status.displayed.id == threadFocusID else { return appearance }
        return appearance.revealingAllParts
    }

    /// `status`の行の中身を組み立てる。見た目の選択肢は`appearance(for:)`に従う。
    func postContentBuilder(for status: Status) -> PostContentBuilder {
        var builder = postContentBuilder
        builder.appearanceOverride = appearance(for: status)
        return builder
    }

    /// 画面に出ている行の前後の投稿の本文を、先に作って並べておく。画面に出ている行の範囲が変わったときだけ頼む。
    func prepareBodiesAroundVisibleRows() {
        let visible = collectionView.indexPathsForVisibleItems.filter { $0.section == 0 }.map(\.item)
        guard let first = visible.min(), let last = visible.max() else { return }
        if let geometry = collectionView.visibleCells.lazy.compactMap({ ($0.contentView as? PostContentView)?.bodyTextGeometry }).first,
           geometry != bodyTextGeometry {
            bodyTextGeometry = geometry
            // 本文の幅が分かる前に頼んだ本文は、文字列だけを作っている。並びも作るよう、同じ範囲でも頼み直す。
            preparedBodyRange = nil
        }
        guard preparedBodyRange != first...last else { return }
        preparedBodyRange = first...last
        let count = collectionView.numberOfItems(inSection: 0)
        // 流している向きの先を先に作る。
        let ahead = Array(min(last + 1, count)..<min(last + 1 + Self.preparedBodyRows, count))
        let behind = Array(max(first - Self.preparedBodyRows, 0)..<first).reversed()
        let rows = lastScrollDirection == .towardNewer ? Array(behind) + ahead : ahead + behind
        var truncations: [Status.ID: BodyTruncation] = [:]
        let statuses = rows.compactMap { item -> Status? in
            guard let id = dataSource.itemIdentifier(for: IndexPath(item: item, section: 0)), let status = entries[id]?.postStatus else { return nil }
            let shown = status.displayed
            truncations[shown.id] = longBodyExpansion.truncation(forBodyOf: status, isThreadFocus: shown.id == threadFocusID, rule: bodyTruncationRule)
            return shown
        }
        if viewIfLoaded?.window != nil {
            translations?.request(((first...last).compactMap(shownStatus(atItem:)) + statuses).flatMap(translationSources(of:)))
        }
        // 本文を出さない設定では、先に作らない。
        guard settings.appearance.showsBody else { return }
        let builder = postContentBuilder
        bodyTextPreparer.prepare(
            statuses,
            renderer: { [translations] status, translated in
                builder.postBodyRenderer(of: status, translation: translated, isTranslating: translations?.isTranslating(TranslationSource(status)) == true)
            },
            geometry: bodyTextGeometry,
            truncation: { truncations[$0.id] },
            translation: { [translations] in translations?.translation(for: TranslationSource($0)) },
            guessesLinkCardDirections: settings.appearance.showsLinkCard
        )
    }

    /// タイムラインの投稿の項目が見せている投稿。ブーストなら元の投稿。通知などの項目ではnil。
    private func shownStatus(atItem item: Int) -> Status? {
        guard let id = dataSource.itemIdentifier(for: IndexPath(item: item, section: 0)) else { return nil }
        return entries[id]?.postStatus?.displayed
    }

    /// 画面に出ている行の前と後ろそれぞれで、本文を先に作る行の数。
    private static let preparedBodyRows = 12
    /// 見本の描き直しを動かす長さ。SwiftUIの`.smooth`の既定の長さと同じ。
    private static let smoothDuration: TimeInterval = 0.5

    /// - Parameters:
    ///   - isPinned: プロフィールの上に置く、固定された投稿。名前の上に固定されていることを示す行を出す。
    ///   - itemID: この中身を置く行。注意書きを開閉したときに、この行の画面上の位置を保つ。
    ///   - translatesBody: 本文を自動翻訳の訳文で出してよい。通知の中の投稿では訳さない。
    func contentConfiguration(for status: Status, isPinned: Bool = false, itemID: ItemID? = nil, translatesBody: Bool = true, base: UIListContentConfiguration) -> PostContentConfiguration {
        let shown = status.displayed
        let appearance = appearance(for: status)
        let builder = postContentBuilder(for: status)
        let connection = itemID.flatMap { replyConnections[$0] } ?? ReplyConnection()
        // スレッドで押した投稿は、開いた時点では返信先がまだ並んでおらずラベルを出しているため、返信先が並んでもラベルを残す。
        // 消すと、読み終えた瞬間に名前と本文がラベルの1行分だけ上へ跳ねる。
        let hidesReplyLabel = hidesReplyLabelBelowParent && connection.parentIsAbove && shown.id != threadFocusID
        let replyLabel = hidesReplyLabel ? nil : ReplyLabel(status: shown, myAccountID: myAccountID)
        let isTranslating = translatesBody && translations?.isTranslating(TranslationSource(status.displayed)) == true
        var configuration = builder.configuration(for: status, isPinned: isPinned, replyLabel: replyLabel, translation: translatesBody ? translatedBody(of: status) : nil, isTranslating: isTranslating, base: base)
        configuration.replyConnection = connection
        // スレッドで開いた投稿だけがアイコンを出すとき、隣の投稿は設定どおりアイコンを出さないので、線でつなぐ先がない。
        if !settings.appearance.showsAvatar {
            configuration.showsReplyLines = false
        }
        configuration.onOpenAccount = { [weak self] in self?.onOpenProfile?(shown.account) }
        configuration.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
        if let itemID {
            configuration.authorTarget = userTarget(for: shown.account, id: itemID)
        }
        if status.reblog != nil, !isPinned {
            configuration.onOpenContextAccount = { [weak self] in self?.onOpenProfile?(status.account) }
            if let itemID {
                configuration.contextTarget = userTarget(for: status.account, id: itemID)
            }
        }
        // フィルターの結果はブーストの外側にだけ付くことがあるため、判定にはブーストごと渡す。
        if !appearance.showsMedia {
            if !shown.mediaAttachments.isEmpty {
                configuration.hiddenSlots.append(.mediaSlot)
            }
        } else if var media = mediaContent(for: status) {
            media.showsBadges = appearance.showsMediaBadges
            configuration.media = media
            configuration.onSelectMedia = { [weak self] index, grid in
                self?.openMedia(media.attachments, at: index, of: shown, from: grid)
            }
        }
        configuration.onRevealMedia = { [weak self] in
            self?.revealMedia(of: shown)
        }
        if appearance.showsPoll {
            configuration.poll = pollContent(for: shown, base: base)
        } else if shown.poll != nil {
            configuration.hiddenSlots.append(.pollSlot)
        }
        configuration.onPollAction = { [weak self] action in self?.handlePollAction(action, on: status, keeping: itemID) }
        configuration.card?.coversImage = mediaCovers.linkCardImageCover(for: shown, display: settings.mediaDisplay) != nil
        if let itemID, let url = configuration.card?.card.url {
            configuration.linkCardTarget = linkTarget(for: url, id: itemID) { [weak self] in self?.onOpenLink?(.url(url), shown) }
        }
        if !appearance.showsQuote, shown.quote != nil {
            configuration.hiddenSlots.append(.quoteSlot)
        }
        if let quote = quoteEmbed(for: status, itemID: itemID, translatesBody: translatesBody, base: base) {
            configuration.embed = quote.content
            configuration.embedActions = quote.actions
        } else if let xPost = xPostContent(for: shown, translatesBody: translatesBody, base: base) {
            configuration.embed = xPost.content
            if let id = XPostLink.postID(of: shown) {
                configuration.embed?.truncation = longBodyExpansion.truncation(forXPost: id, isThreadFocus: shown.id == threadFocusID, rule: bodyTruncationRule)
                configuration.embedActions.expandBody = { [weak self] in self?.expandBody(.xPost(id), keeping: itemID) }
            }
            configuration.embedActions.open = { [weak self] _ in self?.onOpenLink?(.url(xPost.url), shown) }
            if let itemID {
                configuration.embedActions.target = externalPostTarget(url: xPost.url, text: xPost.text, translation: translatesBody ? TranslationSource(xPost.post) : nil, id: itemID) { [weak self] in self?.onOpenLink?(.url(xPost.url), shown) }
            }
            configuration.embedActions.selectMedia = { [weak self] index, grid in
                self?.openMedia(xPost.media, at: index, of: shown, from: grid)
            }
            // 投稿した人が付けた閲覧注意でぼかしているため、ぼかしを外すと、投稿の添付ファイルとそろって外れる。
            configuration.embedActions.revealMedia = { [weak self] in self?.revealMedia(of: shown) }
            configuration.embedActions.openLink = { [weak self] destination in self?.onOpenLink?(destination, shown) }
            if case .link(let quoteURL) = xPost.post.quote {
                configuration.embedActions.selectNote = { [weak self] _ in self?.onOpenLink?(.url(quoteURL), shown) }
            }
        }
        if case .card(let card)? = configuration.card?.card, let attachment = card.imageAttachment {
            configuration.onOpenLinkCardImage = { [weak self] thumbnail in
                // 開いている間に行が別の投稿に使い回されていたら、その画像へは戻さず、薄くして閉じる。
                self?.openMedia([attachment], at: 0, subject: OperationStatus.Subject(shown)) { [weak thumbnail] _ in
                    thumbnail?.isShowing(attachment.url) == true ? thumbnail : nil
                }
            }
        }
        configuration.filterWarning = filterWarning(of: status, base: base)
        configuration.spoiler = spoiler(of: status, base: base, builder: builder)
        let ownMatchTitles = filterWarnings.verdict(for: status).ownMatchTitles
        if !ownMatchTitles.isEmpty {
            if appearance.showsFilterNote {
                configuration.filterNote = builder.ownFilterNote(titles: ownMatchTitles)
            } else {
                configuration.hiddenSlots.append(.filterNoteSlot)
            }
        }
        configuration.onToggleSpoiler = { [weak self] kind in self?.toggleSpoiler(kind, of: status, keeping: itemID) }
        configuration.animatesTextEdit = isShiftingRows
        configuration.bodyTruncation = longBodyExpansion.truncation(forBodyOf: status, isThreadFocus: shown.id == threadFocusID, rule: bodyTruncationRule)
        configuration.onExpandBody = { [weak self] in self?.expandBody(.status(shown.id), keeping: itemID) }
        if capabilities.supportsEmojiReactions {
            configuration.reactionTransitionDuration = tuning.value(of: TuningCatalog.reactionTransitionDuration)
        }
        if showsActionBar(itemID: itemID, shown: shown) {
            configuration.actionBar = actionBarContent(for: status, itemID: itemID, countFont: configuration.metrics.timeFont, canSelectText: Self.showsSelectableBody(configuration))
            if let itemID {
                configuration.onActionBarPress = { [weak self] item, button in self?.performActionBarItem(item, id: itemID, from: button) }
                configuration.actionBarLongPressTarget = { [weak self] item in self?.actionBarLongPressTarget(for: item, id: itemID) }
            }
        }
        if capabilities.supportsEmojiReactions, let reactions = builder.reactionChips(for: shown, localEmojis: localReactionEmojis) {
            configuration.reactions = reactions
            configuration.onToggleReaction = { [weak self] name in
                guard let emoji = shown.emojiReactions.first(where: { $0.emoji.name == name })?.emoji else { return }
                self?.onToggleEmojiReaction?(status, emoji)
            }
            if onAddEmojiReaction != nil {
                configuration.onAddReaction = { [weak self] in self?.onAddEmojiReaction?(status) }
            }
            configuration.reactionTarget = { [weak self] name in
                guard let reaction = shown.emojiReactions.first(where: { $0.emoji.name == name }) else { return nil }
                return self.map { $0.reactionTarget(for: status, reaction: reaction.resolvingImage(in: $0.localReactionEmojis)) }
            }
        }
        return isAppearancePreview ? Self.keepingOnlyLinks(configuration) : configuration
    }

    #if DEBUG
    /// 一番上に見えている投稿の行の投稿と、その行の画面（ウインドウ）での上端。デバッグのURLで、対象の投稿を選ぶのに使う。
    func topmostVisibleStatus() -> (status: Status, minY: CGFloat)? {
        guard let window = view.window else { return nil }
        let visibleTop = collectionView.convert(CGPoint(x: 0, y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top), to: window).y
        return collectionView.visibleCells.compactMap { cell -> (Status, CGFloat)? in
            guard let id = collectionView.indexPath(for: cell).flatMap({ dataSource.itemIdentifier(for: $0) }), let status = entries[id]?.postStatus else { return nil }
            let frame = cell.convert(cell.bounds, to: window)
            return frame.maxY > visibleTop ? (status, frame.minY) : nil
        }
        .min { $0.1 < $1.1 }
        .map { (status: $0.0, minY: $0.1) }
    }

    /// 並べている投稿のうち、IDの投稿。ブーストなら、元の投稿のIDでも探す。
    func loadedStatus(id: Status.ID) -> Status? {
        entries.values.lazy.compactMap(\.postStatus).first { $0.id == id || $0.reblog?.id == id }
    }
    #endif

    /// プレビューの見本で、本文やリンクカードのリンクを押す操作だけを残す。見本の写真のクレジットのリンクを開けるようにするため。
    /// ほかの操作（サムネイル、投票、注意書きの開閉、名前やアイコンなど）は、見本を変えたり別の画面を開いたりするので外す。
    static func keepingOnlyLinks(_ configuration: PostContentConfiguration) -> PostContentConfiguration {
        var kept = configuration
        kept.onSelectMedia = nil
        kept.onRevealMedia = nil
        kept.onToggleSpoiler = nil
        kept.onExpandBody = nil
        kept.onOpenAccount = nil
        kept.onOpenContextAccount = nil
        kept.authorTarget = nil
        kept.contextTarget = nil
        kept.onOpenLinkCardImage = nil
        // リンクカードの対象を外すと、カードのタップは`onOpenLink`で開く。
        kept.linkCardTarget = nil
        kept.onPollAction = nil
        kept.onToggleReaction = nil
        kept.reactionTarget = nil
        // アクションバーのボタンは、見本では押しても何もしない。
        kept.onActionBarPress = nil
        kept.actionBarLongPressTarget = nil
        // 「＋」は渡すかどうかで出すかが決まるので、出すものは押しても何もしない処理にして残す。
        kept.onAddReaction = configuration.onAddReaction.map { _ in {} }
        kept.embedActions = EmbedActions(openLink: configuration.embedActions.openLink)
        // リンクのタップと長押しの設定によらず、タップで開く。
        kept.opensLinksOnTapOnly = true
        return kept
    }

    /// リストのアイテムにアクションバーを出せるか。出すのは投稿だけで、通知には出さない（docs/post-action-bar.mdの「出し方」）。
    func canShowActionBar(in entry: TimelineEntry) -> Bool {
        !isAppearancePreview && entry.operatedPost != nil
    }

    /// 投稿にアクションバーを出すか。いつも出す設定か、引き出しを開いている投稿で出す。
    /// 「投稿の見た目」のプレビューと、アイテムのIDを渡さずに組む見本では、いつも出す設定のときだけ出す。見本の投稿はタイムラインのアイテムとして並ばないため、アイテムのIDでは決めない。
    func showsActionBar(itemID: ItemID?, shown: Status) -> Bool {
        guard !isAppearancePreview, let itemID else { return settings.appearance.showsActionBar || showsActionBarInPreview }
        guard let entry = entries[itemID], canShowActionBar(in: entry) else { return false }
        return appearance(for: shown).showsActionBar || openActionBarItemID == itemID
    }

    /// アクションバーの中身。押せない項目は、メニューと同じ組み方で決めて薄く描く。
    /// 組むだけで通信しない投稿のメニューの木で決める。メニューを出すときと違い、メニューに出る人の関係は読み直さず、カスタム絵文字の画像も読まない。
    /// - Parameter canSelectText: これから置く本文を選べるか。投稿のセルはまだこの中身を置いていないので、置いてある本文からは決めない。
    private func actionBarContent(for status: Status, itemID: ItemID?, countFont: UIFont, canSelectText: Bool) -> PostActionBarContent {
        let shown = status.displayed
        let builder = postContentBuilder(for: status)
        guard let itemID else { return builder.actionBar(for: shown, countFont: countFont) { _ in true } }
        return FrameWork.measure("actionBar") {
            let tree = offlineStatusMenuTree(for: status, id: itemID, canSelectText: canSelectText)
            return builder.actionBar(for: shown, countFont: countFont) { item in
                MenuItemOutcome(singleItemMenu: tree.menu(groups: .single(item), includesFollowRequest: false).root).isAvailable
            }
        }
    }

    /// 項目を出せるかや今の名前を決めるための、投稿のメニューの木。アクションバーのボタンと投稿のスワイプのボタンで使う。
    /// 組むだけで通信しない。メニューを出すときと違い、メニューに出る人の関係は読み直さず、カスタム絵文字の画像も読まない。
    func offlineStatusMenuTree(for status: Status, id: ItemID, canSelectText: Bool) -> StatusMenuTree {
        let notification: MastodonNotification? = if case .notification(let notification) = entry(for: id) { notification } else { nil }
        var tree = statusMenuTree(status: status, notification: notification, id: id, canSelectText: canSelectText)
        let emojiGroups = settings.customEmojiMenuLayout.groups
        tree.customEmoji = { [weak self] emoji in
            self?.customEmojiMenuTree(for: emoji).submenu(groups: emojiGroups)
        }
        return tree
    }

    /// 中身を置いたときに、本文を「テキストを選択」で選べるか。本文があり、注意書きで折りたたんでいないときに選べる。
    /// 長い本文を切るかは、並べた幅で決まるので、ここでは分からない。切った本文では、押すと選べないことをチップで知らせる（docs/object-actions.mdの「項目を行う」）。
    /// 切ったかを並べたあとに読んでボタンを描き直すには、投稿を組み直す経路が要り、それに見合わないため、切る本文でも押せる色で描く。
    private static func showsSelectableBody(_ configuration: PostContentConfiguration) -> Bool {
        configuration.filterWarning?.isCollapsed != true && configuration.spoiler?.isCollapsed != true && !configuration.body.string.allSatisfy(\.isWhitespace)
    }

    /// 投稿の下のアクションバーの引き出しを開閉する。開いている投稿で押せば閉じ、別の投稿で開けば前の投稿のアクションバーは閉じる。
    /// 押した投稿の画面上の位置を保ち、まわりのアイテムごと動かしてつなぐ（docs/vision.mdの「タイムラインの動き」）。
    /// その投稿にアクションバーがいつも出ているとき（いつも出す設定か、すべての部品を見せるスレッドの中心の投稿）は、何もせず、nilを返す。
    /// - Returns: 開閉したら、動きが着くまでの時間（スプリングの知覚上の長さ）。動かさずに開閉したら0。
    @discardableResult
    func toggleActionBar(for id: ItemID) -> TimeInterval? {
        guard let status = entries[id]?.operatedPost, !appearance(for: status).showsActionBar else { return nil }
        let previous = openActionBarItemID
        openActionBarItemID = previous == id ? nil : id
        let ids = Set([previous, id].compactMap(\.self)).intersection(dataSource.snapshot().itemIdentifiers)
        let duration = tuning.value(of: TuningCatalog.actionBarDrawerDuration)
        reconfigureShiftingRowsBelow(ids, keeping: id, duration: duration, shiftLimit: actionBarHeightUpperBound)
        if let opened = openActionBarItemID {
            revealActionBarFromItsTop(of: opened, duration: duration)
        }
        return animatesRowShift(duration: duration) ? duration : 0
    }

    /// 引き出しのアクションバーを、初めて開く前に1つ組んでおいたか。
    private var hasPreparedActionBar = false

    /// タップか長押しかスワイプに「アクションバーを開く」を割り当てていれば、タイムラインを出したあとに、見えている投稿のアクションバーを1つ組んで捨てる。
    /// 起動して初めて開くときは、アクションバーの部品と記号の画像を初めて作り、投稿のメニューの木も初めて組むので、押してから最初のコマまでが2回目より大きく遅れ、
    /// 動き始めのコマが飛んで見えた（シミュレーターで、初めては73ミリ秒、2回目は6ミリ秒）。先に組んでおけば、初めて開くときも2回目と同じになる。
    /// いつも出す設定では、投稿を組むときにアクションバーも組むので、ここでは組まない。
    private func prepareActionBarIfNeeded() {
        guard !hasPreparedActionBar, !isAppearancePreview, !settings.appearance.showsActionBar, settings.opensActionBarByGesture else { return }
        hasPreparedActionBar = true
        Task(.withoutRequests) { @MainActor [weak self] in
            guard let self else { return }
            guard let (id, status) = collectionView.indexPathsForVisibleItems.lazy.compactMap({ indexPath -> (ItemID, Status)? in
                      guard let id = self.dataSource.itemIdentifier(for: indexPath), let entry = self.entries[id], self.canShowActionBar(in: entry), let status = entry.operatedPost else { return nil }
                      return (id, status)
                  }).first
            else {
                hasPreparedActionBar = false
                return
            }
            let content = actionBarContent(for: status, itemID: id, countFont: PostTypography(settings: settings).font(.time), canSelectText: false)
            let width = collectionView.bounds.width
            let bar = PostActionBarView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
            bar.apply(content)
            // 親のない部品は自分の高さを決めないので、中身に合う高さを測ってから並べて描く。
            let height = bar.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            bar.frame.size.height = height
            bar.layoutIfNeeded()
            // 画面に出していない部品は描かれないので、記号の画像は別に一度描いておく。初めて描くときの重さが、初めて開いたコマに残るため。
            bar.drawForPreparation()
        }
    }

    /// アクションバーを開閉して投稿が伸び縮みする長さの上限。本文とのあいだ、上下の余白、アイコンの大きさから、件数の文字の高さを見込んで大きめに決める。
    /// タイムラインの外へ出うるアイテムの像を取るのに使う。少なく見込むと、外へ出るアイテムが像なしで一度に消えるため、大きめにする。
    private var actionBarHeightUpperBound: CGFloat {
        let icon = settings.value(of: AppearanceCatalog.actionBarIconSize)
        let lineHeight = max(icon * 2, PostTypography(settings: settings).font(.time).lineHeight * 2)
        return settings.value(of: AppearanceCatalog.actionBarSpacing) + settings.value(of: AppearanceCatalog.actionBarPadding) * 2 + lineHeight
    }

    /// 開いたアクションバーを、上の端から下へ、まわりのアイテムと同じスプリングで切り抜いて現す。
    /// 開く前の投稿の下の余白は、開いたあとのアクションバーの上の部分に重なるので、投稿の切り抜き（`revealGrowth`）だけでは、その部分が最初のコマで一度に見えた。
    /// 投稿全体の切り抜きをアクションバーの上の端から広げ直すと、アイコンの下の端がアクションバーの上の端より下に出る短い投稿で、開く前から見えていたアイコンまで一度消えるため、アクションバーだけを切り抜く。
    private func revealActionBarFromItsTop(of id: ItemID, duration: TimeInterval) {
        guard duration > 0, view.window != nil, !UIAccessibility.isReduceMotionEnabled,
              let bar = (cell(for: id)?.contentView as? PostContentView)?.postBody.actionBar
        else { return }
        let mask = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = .zero
        mask.frame = bar.layer.bounds
        CATransaction.commit()
        let grow = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        grow.fromValue = 0
        grow.toValue = bar.bounds.height
        grow.delegate = RowShiftCompletion { [weak bar, weak mask] in
            guard let bar, let mask, bar.layer.mask === mask else { return }
            bar.layer.mask = nil
        }
        mask.add(grow, forKey: Self.actionBarRevealName)
        bar.layer.mask = mask
    }

    /// アクションバーを現す切り抜きの動きの名前。
    static let actionBarRevealName = "actionBarReveal"

    /// 縮む前の像を縮める切り抜きの動きの名前。
    static let shrinkName = "rowShrink"

    /// 長い本文を切る行数。「投稿の見た目」の値で決める。
    var bodyTruncationRule: BodyTruncation? {
        BodyTruncation(
            threshold: Int(settings.value(of: AppearanceCatalog.bodyTruncationThreshold)),
            lines: Int(settings.value(of: AppearanceCatalog.bodyTruncatedLines))
        )
    }

    /// 切った本文を「続きを読む」で広げる。同じ投稿を出している行（ブースト、通知、引用の囲み）もまとめて描き直す。
    /// 広げる行は上端を動かさずに下へ伸びるので、行の位置を保って描き直し、下の行を元の位置から動かしてつなぐ。
    /// - Parameter anchorID: 押した行。同じ投稿の行が上にも並んでいると、その行も伸びるため、押した行の画面上の位置を保つ。
    func expandBody(_ key: LongBodyExpansion.Key, keeping anchorID: ItemID? = nil) {
        longBodyExpansion.expand(key)
        onChangeLongBodyExpansion?(longBodyExpansion, key)
        guard isViewLoaded else { return }
        reconfigureShiftingRowsBelow(Set(itemIDs(expanding: key)), keeping: operatedAnchor(anchorID), duration: tuning.value(of: TuningCatalog.longBodyExpandDuration))
    }

    /// ほかのタイムラインで広げた本文を、このタイムラインにもそろえる。使う人がこのタイムラインで行った操作ではないので、動かさずに描き直し、読んでいる行の位置を保つ。
    func applyLongBodyExpansion(_ expansion: LongBodyExpansion, changed key: LongBodyExpansion.Key) {
        longBodyExpansion = expansion
        // まだ開いていない画面は、開いたときにこの状態で描く。描き直しのために画面を読み込ませない。
        guard isViewLoaded else { return }
        reconfigure(Set(itemIDs(expanding: key)))
    }

    /// 広げた本文を出している行。
    private func itemIDs(expanding key: LongBodyExpansion.Key) -> [ItemID] {
        displayedItemIDs.filter { id in
            guard let displayed = status(for: id)?.displayed else { return false }
            return switch key {
            case .status(let statusID): displayed.id == statusID || displayed.quote?.quotedStatus?.id == statusID
            case .xPost(let postID): XPostLink.postID(of: displayed) == postID
            }
        }
    }

    /// 注意書きかフィルターの警告を開閉する。同じ投稿をブーストした行と通知の行もまとめて描き直す。
    /// 行の高さが変わるため、押した行の画面上の位置を保つ。同じ投稿の行が上にも並んでいると、その行も伸び縮みするため、
    /// 表示領域の上端の行を基準にすると、押した行がずれる。
    /// - Parameter kind: 押したボックス。
    /// - Parameter anchorID: 押した行。なければ、表示領域の上端にかかっている行を基準にする。
    func toggleSpoiler(_ kind: PostBodyContent.Spoiler.Kind = .contentWarning, of status: Status, keeping anchorID: ItemID? = nil) {
        switch kind {
        case .contentWarning: spoilerExpansion.toggle(status)
        case .filter: filterWarnings.toggle(status)
        }
        guard isViewLoaded else { return }
        reconfigureShiftingRowsBelow(Set(itemIDs(showing: status)), keeping: operatedAnchor(anchorID), duration: tuning.value(of: TuningCatalog.longBodyExpandDuration))
    }

    /// 使う人の操作で行を描き直すときに、位置を保つ行。押した行が渡されなければ、表示領域の上端にかかっている行にする。
    /// 基準を渡さずに描き直すと、使う人の操作によらない変化として、上端が表示領域より上にある行を上へ伸ばす（`upwardResizingRow`）。
    func operatedAnchor(_ anchorID: ItemID?) -> ItemID? {
        anchorID ?? currentAnchor()?.id
    }

    /// `status`を出している行。ブーストした行、通知の行と、引用の囲みに出している行も含める。
    func itemIDs(showing status: Status) -> [ItemID] {
        let shownID = status.displayed.id
        return displayedItemIDs.filter { id in
            guard let displayed = self.status(for: id)?.displayed else { return false }
            return displayed.id == shownID || displayed.quote?.quotedStatus?.id == shownID
        }
    }

    func avatarContent(of account: Account) -> AvatarView.Content {
        postContentBuilder.avatarContent(of: account)
    }

    func body(of status: Status, base: UIListContentConfiguration, color: UIColor = .label) -> NSAttributedString {
        postContentBuilder.body(of: status, base: base, color: color)
    }

    /// フィルターの警告。開いているかは、このタイムラインで覚えている状態を当てる。警告のフィルターに一致しなければnil。
    func filterWarning(of status: Status, base: UIListContentConfiguration) -> PostBodyContent.Spoiler? {
        guard let warning = filterWarnings.warning(for: status) else { return nil }
        var box = postContentBuilder.filterWarning(titles: warning.titles, base: base)
        box.isCollapsed = !warning.isRevealed
        return box
    }

    /// 注意書き。開いているかは、このタイムラインで覚えている状態を当てる。ブーストなら元の投稿の注意書きにする。
    /// - Parameter font: 注意書きの文字の書体。nilなら本文の文字で描く。
    /// - Parameter builder: 組み立てに使う部品。渡さなければ設定の見た目の選択肢で組む。
    func spoiler(of status: Status, base: UIListContentConfiguration, color: UIColor = .label, font: UIFont? = nil, builder: PostContentBuilder? = nil) -> PostBodyContent.Spoiler? {
        var spoiler = (builder ?? postContentBuilder).spoiler(of: status.displayed, base: base, color: color, font: font)
        spoiler?.isCollapsed = spoilerExpansion.isCollapsed(status)
        return spoiler
    }
}

extension TimelineViewController: LinkMenuHost {
    func linkMenuWillShow() {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
        contextMenuIcons.menuWillAppear(in: view.window)
    }

    func linkMenuDidHide() {
        contextMenuIcons.menuWillEnd()
        menuDidHide()
    }

    func showLinkCopiedNotice() {
        showNotice(.linkCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func showHandleCopiedNotice(_ part: UserHandlePart) {
        showNotice(.handleCopied(part), duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    func openURL(_ url: URL, in browser: LinkBrowser) {
        onOpenURL?(url, browser)
    }

    func openProfile(resolving url: URL) {
        onOpenProfileURL?(url)
    }

    func openHashtag(_ name: String, of account: Account) {
        onOpenAccountHashtag?(name, account)
    }
}

extension TimelineViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        FrameWork.measure("scrollViewDidScroll") { handleScroll(scrollView) }
    }

    /// 下端の覆われた部分はsafe areaから外れ、表示領域が変わるので、そこに隠れた要素を表示中として報告しないよう、報告し直す。
    /// safe areaが変わった知らせの時点では、タイムラインの余白はまだ変わっていないため、ここで報告する。
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        guard scrollView.adjustedContentInset.bottom != reportedBottomInset else { return }
        reportedBottomInset = scrollView.adjustedContentInset.bottom
        reportVisibleItems()
    }

    private func handleScroll(_ scrollView: UIScrollView) {
        prepareBodiesAroundVisibleRows()
        if scrollView.isTracking {
            // 指が下へ動いていれば、内容は上の新しい投稿の方へ動く。
            let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
            if velocity != 0 {
                lastScrollDirection = velocity > 0 ? .towardNewer : .towardOlder
            }
        }
        reportVisibleItems(byUser: isUserScrolling)
        // 並びを置き換えて位置を補正している途中の位置では決めない。最上部で新着に追従するときは、補正で一度下へずれてから最上部へ戻るため。
        // 置き換えを終えたところで決め直す。
        if !isRestoringAnchor {
            updateNewArrivalsButtonArrow()
        }
        reportApproachingGaps()
        onScroll?(scrollView)
        // 最上部からさらに引っぱっている間は、浮かぶ新着のボタンもタイムラインと一緒に下げる。上に現れるストリーミングの状態を覆わないようにする。
        // チップの列は下げない。十分に引っぱれば、一番上の投稿とストリーミングの状態が列の下に見えるため。
        let pulled = max(-(scrollView.contentOffset.y + scrollView.adjustedContentInset.top), 0)
        if pulled != pulledDistance {
            pulledDistance = pulled
            newArrivalsButton.transform = CGAffineTransform(translationX: 0, y: pulled)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            recordScroll()
            reportVisibleItemsAfterLayout(byUser: true)
            reportInteractionSettled()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        recordScroll()
        reportVisibleItemsAfterLayout(byUser: true)
        reportInteractionSettled()
    }

    /// 返信先の投稿へ動かしたとき。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportVisibleItemsAfterLayout()
        reportInteractionSettled()
    }

    /// 最上部へ動かしている途中で指が触れたら、そこで止める。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopSpringScroll()
        // 慣性で動いている途中で触れると、前のスクロールは止まりの通知を受けずに終わるため、ここで記録する。
        recordScroll()
        scrollStart = (scrollView.contentOffset.y, mediaTime())
        scrollHitches.start()
    }

    /// スクロールの途中で新着の挿入などにより位置を補正すると、補正の分も動いた量に入る。
    private func recordScroll() {
        guard let start = scrollStart else { return }
        scrollStart = nil
        let (hitches, work) = scrollHitches.finish()
        FrameWorkLog.record(work, screen: texts.dumpName)
        UserAction.scroll(ScrollRecord(
            screen: texts.dumpName,
            startOffset: start.offset,
            endOffset: collectionView.contentOffset.y,
            viewportHeight: collectionView.bounds.inset(by: collectionView.adjustedContentInset).height,
            duration: mediaTime() - start.time,
            hitches: hitches
        )).record()
    }

    /// 指を離したときの勢いで向きを決め直す。慣性で動く間はこの向きのまま。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if velocity.y != 0 {
            lastScrollDirection = velocity.y < 0 ? .towardNewer : .towardOlder
        }
    }

    /// ステータスバーのタップ。UIKitに動かさせず、新着ボタンと同じ動きで最上部へ戻る。
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        scrollToNewest()
        UserAction.scrollToTop(screen: texts.dumpName).record()
        return false
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
        contextMenuIcons.menuWillAppear(in: view.window)
    }

    /// 閉じるアニメーションが終わるまでは、メニューを出している扱いにする。
    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        contextMenuIcons.menuWillEnd()
        guard let animator else {
            menuDidHide()
            return
        }
        animator.addCompletion { [weak self] in self?.menuDidHide() }
    }

    /// 長押しで投稿への操作のメニューを出す。添付ファイルのサムネイルとリンクカードの画像はボタンで、ここへは届かないため、
    /// それぞれが`MediaMenuHost`に問い合わせてメディアのメニューを出す。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        if isAppearancePreview { return nil }
        // 選んでいる本文の上の長押しは、テキストビューが単語を選ぶのに使う。
        if let body = textSelectionBody, let frame = body.textSelectionFrame, body.convert(frame, to: collectionView).contains(point) { return nil }
        // 投稿を選んでいる間は、行のコンテキストメニューを出さない。
        if isSelectingPosts { return nil }
        if indexPaths.count == 1, let indexPath = indexPaths.first, rowTarget(at: indexPath)?.performsLongPress() == true { return nil }
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let entry = entry(for: id),
              let menu = contextMenu(for: entry, id: id)
        else { return nil }
        // 指の位置にメニューを出せるよう、押した場所をidentifierに持たせる。
        return UIContextMenuConfiguration(identifier: NSValue(cgPoint: point), previewProvider: nil) { _ in menu }
    }

    /// 行を持ち上げず、指の位置の見えない目印をプレビューにして、メニューだけを指の位置に出す。
    /// 行を持ち上げると、閉じるときにガラスのメニューが行の大きさまで広がって吸い込まれ、行の真ん中の文字が波紋のようにゆがむため。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        anchorPreview(for: configuration)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration, dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        anchorPreview(for: configuration)
    }

    private func anchorPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let point = (configuration.identifier as? NSValue)?.cgPointValue else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UITargetedPreview(view: anchor, parameters: parameters, target: UIPreviewTarget(container: collectionView, center: point))
    }

    /// 選べるのはギャップと、ブラウザで開ける読めなかった要素と、スレッドを開ける投稿と、投稿を含む通知と、人のリストの人にする。
    /// 本文のリンクや添付ファイルなど、行の中の部品が押下を先に受けるため、投稿の行を選ぶのは、どの部品も受けなかったときだけになる。
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if isAppearancePreview { return false }
        // 本文を選んでいる間の行のタップは、選ぶのをやめるだけにし、行の操作は行わない。
        if endTextSelection() { return false }
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        // 投稿を選んでいる間の行のタップは、その行を選ぶか外すかだけにする。
        if isSelectingPosts { return canSelectPost(id) }
        return switch (id, entries[id]) {
        case (.gap, _): true
        case (_, .unreadable(let item)): item.url != nil || item.isCrashQuarantined
        case (_, .search(let row)): !row.isHeading
        // 投稿、通知、人のリストの行は、タップに選んだ操作を行う。既定の操作が行えない行（スレッドの中心の投稿、投稿のない通知）は、今どおり押せないままにする。
        case (_, .status), (_, .pinned), (_, .notification), (_, .account), (_, .notificationRequest): rowTarget(at: indexPath)?.acceptsTap ?? false
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        // 本文を選んでいる間は、どの行のタップでも選ぶのをやめられるよう、押せない行でも選ぶ処理まで進める。
        if isSelectingText { return true }
        return self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    private var isSelectingText: Bool {
        textSelectionBody?.isSelectingText == true
    }

    /// `id`の行に出している本文のうち、「テキストを選択」で選べるもの。行が画面にないとき、別の投稿（引用の囲みなど）のメニューのとき、選べないときはnil。
    func selectableBody(for id: ItemID, statusID: Status.ID) -> PostBodyView? {
        guard let indexPath = dataSource.indexPath(for: id), let contentView = collectionView.cellForItem(at: indexPath)?.contentView else { return nil }
        let body = (contentView as? PostContentView)?.postBody ?? (contentView as? NotificationContentView)?.postBody
        guard let body, body.content?.statusID == statusID, body.canSelectText else { return nil }
        return body
    }

    /// 本文を選べる状態にする。ほかの行で選んでいれば、そちらはやめる。メニューを出している間は、閉じ終えてから選ぶ。
    func beginTextSelection(in body: PostBodyView, statusID: Status.ID) {
        if isShowingMenu {
            pendingTextSelection = (body, statusID)
            return
        }
        endTextSelection()
        body.beginTextSelection()
        textSelectionBody = body
    }

    /// 選べる状態の本文があれば、やめる。やめたらtrue。
    @discardableResult
    func endTextSelection() -> Bool {
        defer { textSelectionBody = nil }
        guard let body = textSelectionBody, body.isSelectingText else { return false }
        body.endTextSelection()
        return true
    }

    /// ギャップは、画面の上半分にあれば下から遡ってきたとみなして古い側から、下半分にあれば新しい側から読む。
    /// どちらも、いま読んでいる側に続く投稿から埋まる。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isSelectingPosts, let id = dataSource.itemIdentifier(for: indexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            togglePostSelection(id)
            return
        }
        if let target = rowTarget(at: indexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            // キーボードや読み上げのように触れずに選んだときは、前に触れた位置ではなく、選んだ行の真ん中にメニューを出す。
            let touched = touchRecorder.lastLocation.flatMap { collectionView.indexPathForItem(at: $0) == indexPath ? $0 : nil }
            let center = collectionView.layoutAttributesForItem(at: indexPath).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            target.perform(.tap, in: collectionView, at: touched ?? center)
            return
        }
        if let id = dataSource.itemIdentifier(for: indexPath), case .search(let row) = entries[id] {
            collectionView.deselectItem(at: indexPath, animated: true)
            onSearchRowSelect?(row)
            return
        }
        if let id = dataSource.itemIdentifier(for: indexPath), case .unreadable(let item) = entries[id], item.isCrashQuarantined {
            collectionView.deselectItem(at: indexPath, animated: true)
            notices?.openCrashReport?(item.id)
            return
        }
        if let id = dataSource.itemIdentifier(for: indexPath), case .unreadable(let item) = entries[id], let url = item.url {
            collectionView.deselectItem(at: indexPath, animated: true)
            UIApplication.shared.open(url)
            return
        }
        guard case .gap(let gapID) = dataSource.itemIdentifier(for: indexPath) else { return }
        UserAction.tapGap(screen: texts.dumpName).record()
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !loadingGapIDs.contains(gapID), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        onGapSelect?(gapID, frame.midY < visibleRect.midY ? .fromOlder : .fromNewer)
    }

    /// 投稿のスレッドを開けるか。スレッドの中心の投稿は、開いているスレッドそのものなので開かない。
    func canOpenThread(of status: Status) -> Bool {
        onOpenThread != nil && status.displayed.id != threadFocusID
    }

    /// 要素の行の、ウインドウでの枠。スレッドを開く動きの起点にする。行が画面になければゼロ。
    /// ブーストした人や返信先の行は、スレッドの行には出ないことがあるため、その行を除いた投稿の中身の枠にする。
    func rowFrame(of id: ItemID) -> CGRect {
        guard let indexPath = dataSource.indexPath(for: id), let cell = collectionView.cellForItem(at: indexPath) else { return .zero }
        let context = Self.contextHeight(of: cell)
        return cell.convert(cell.bounds, to: nil).inset(by: UIEdgeInsets(top: context, left: 0, bottom: 0, right: 0))
    }

    private static func contextHeight(of cell: UICollectionViewCell) -> CGFloat {
        (cell.contentView as? PostContentView)?.contextHeight ?? 0
    }

    /// スレッドを開いたことを、違和感レポートの操作の記録に残す。
    func recordOpenThread() {
        UserAction.openThread(screen: texts.dumpName).record()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // 最初にスクロールする前にも、画面の前後の本文を先に作っておく。スクロールのたびに頼むだけでは、起動して最初に流した数行に間に合わない。
        prepareBodiesAroundVisibleRows()
        if TimelineLoadTrigger.isApproachingEnd(displaying: indexPath.item, count: dataSource.snapshot().numberOfItems) {
            onApproachingEnd?()
        }
    }
}

extension TimelineViewController: UICollectionViewDataSourcePrefetching {
    /// スクロールで画面に入りそうな行のアイコンを読み始める。
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchAvatars(for: indexPaths.compactMap { dataSource.itemIdentifier(for: $0).flatMap { entries[$0] } })
    }
}

extension TimelineViewController: UIGestureRecognizerDelegate {
    /// 触れて止めたまま、指でスクロールし始められるようにする。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === springScrollInterruption && otherGestureRecognizer === collectionView.panGestureRecognizer
    }
}

// MARK: - スクロール位置の保持

extension TimelineViewController {
    /// 更新の前後で画面上の位置を揃える基準の投稿と、そのセル上端の、表示領域上端からの距離。
    struct ScrollAnchor {
        let id: ItemID
        let distanceFromVisibleTop: CGFloat
    }

    /// 表示領域の上端にかかっている、最も上の投稿を基準にする。
    /// 上端にかかる分が半画素に満たない行は、見えていない行として扱う。行の位置は高さを足し合わせて決まるため、
    /// 上の行の下端が表示領域の上端にぴったり重なるはずのときも、浮動小数点の誤差でわずかに下へずれ、隠れた上の行を基準に選んでしまうため。
    /// - Parameter candidates: 基準にしてよい行。nilなら、見えている行のどれでもよい。
    func currentAnchor(among candidates: Set<ItemID>? = nil) -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let halfPixel = 0.5 / max(collectionView.traitCollection.displayScale, 1)
        let topmost = collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (ItemID, CGRect)? in
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      candidates?.contains(id) ?? true,
                      let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
                else { return nil }
                return (id, frame)
            }
            .filter { $0.1.maxY > visibleTop + halfPixel }
            .min { $0.1.minY < $1.1.minY }
        guard let (id, frame) = topmost else { return nil }
        return ScrollAnchor(id: id, distanceFromVisibleTop: frame.minY - visibleTop)
    }

    /// `frame`が表示領域の上端`visibleTop`より下に半画素以上かかっていれば、見えていると見なす。
    /// ヘッダーの下端が表示領域の上端にぴったり重なるはずのときも、スクロール位置と上の余白を足し引きする浮動小数点の誤差で、わずかに下へずれるため。
    private func isVisible(_ frame: CGRect, below visibleTop: CGFloat) -> Bool {
        frame.maxY > visibleTop + 0.5 / max(collectionView.traitCollection.displayScale, 1)
    }

    /// ヘッダーの中身が変わって高さが変わったときに呼ぶ。ヘッダーを読み終えて下の投稿を読んでいれば、その投稿の位置を変えない。
    /// ヘッダーが見えていれば、ヘッダーが伸び縮みした分だけ下の投稿が動くのに任せる。
    /// 画面を読み込む前は、最初の表示で測るため何もしない。
    func headerDidChangeSize() {
        guard headerView != nil, isViewLoaded, dataSource.snapshot().numberOfSections > 0 else { return }
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        collectionView.layoutIfNeeded()
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let headerFrame = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 0)
        )?.frame
        let anchor = (headerFrame.map { !isVisible($0, below: visibleTop) } ?? false) ? currentAnchor() : nil
        if let anchor {
            collectionView.collectionViewLayout.invalidateLayout()
            restore(anchor)
        } else {
            // ヘッダーが見えている間は、ヘッダーを動かさず、伸び縮みした分だけ下の行を動かす。
            // 作り直したレイアウトでは、ヘッダーの高さが見積もり（28pt）に戻り、その高さで画面に入るときだけ測り直される。
            // ヘッダーの上端が画面の上の外にあると、見積もりのまま画面外と見なされ、ヘッダーが消える。
            // そのため、作り直す間だけ一番上へ移して測らせ、同じフレームの中で元の位置へ戻す。
            let offset = collectionView.contentOffset.y
            let top = -collectionView.adjustedContentInset.top
            collectionView.contentOffset.y = top
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            let bottom = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height
            // 一番上から引っぱっている間（上端より上）は、引っぱった分をそのまま戻す。上端に詰めると、指を離す前にヘッダーが跳ぶ。
            collectionView.contentOffset.y = offset < top ? offset : min(offset, max(bottom, top))
            collectionView.layoutIfNeeded()
        }
    }

    /// ヘッダーの中身が変わって伸び縮みした分を、ヘッダーの下の内容と下の行ごとスプリングで動かしてつなぐ。動きの途中も操作を受け付ける。
    /// ヘッダーを読み終えて下の行を読んでいるときと、`duration`が0のときは、動かさずに`headerDidChangeSize()`と同じく位置を保つ。
    func headerDidChangeSize(animatingWithDuration duration: TimeInterval) {
        guard duration > 0, view.window != nil, headerView != nil, dataSource.snapshot().numberOfSections > 0 else {
            headerDidChangeSize()
            return
        }
        let header = IndexPath(item: 0, section: 0)
        // ここで並べ直すと、伸びた中身を前の高さのヘッダーに押し込んだ形が、動きの出発点になってしまう。並べ直すのは動きの中だけにする。
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard let headerFrame = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: header)?.frame,
              isVisible(headerFrame, below: visibleTop)
        else {
            headerDidChangeSize()
            return
        }
        let offset = collectionView.contentOffset.y
        UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            let context = UICollectionViewLayoutInvalidationContext()
            context.invalidateSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader, at: [header])
            self.collectionView.collectionViewLayout.invalidateLayout(with: context)
            self.collectionView.layoutIfNeeded()
            // ヘッダーの上端が表示領域の上端より上にあると、タイムラインは下の行の位置を保とうとして、伸びた分だけスクロール位置を足す。
            // それではヘッダーが上へ伸びて見えるため、`headerDidChangeSize()`と同じく、ヘッダーを動かさず下の行を動かす位置に戻す。
            let top = -self.collectionView.adjustedContentInset.top
            let bottom = self.collectionView.contentSize.height + self.collectionView.adjustedContentInset.bottom - self.collectionView.bounds.height
            self.collectionView.contentOffset.y = offset < top ? offset : min(offset, max(bottom, top))
        }
    }

    /// 画面に出るときに、`id`の行の上端を、ウインドウの`windowY`の高さに置く。スレッドを、押した行をタイムラインで見えていた位置に置いて開くのに使う。
    /// 画面に出るまでは、安全領域とバーの高さが分からないため、出るときに置く。
    func placeOnAppearing(_ id: ItemID, atWindowY windowY: CGFloat) {
        pendingOpening = (id, windowY)
    }

    /// 開いた時点では押した行の上に並ぶ行がないため、上の余白を足して、押した行を押した位置まで下げる。
    private func applyPendingOpening() {
        guard let opening = pendingOpening, let window = view.window else { return }
        pendingOpening = nil
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: opening.id),
              var frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return }
        // 押した行と同じく、ブーストした人や返信先の行を除いた投稿の中身の上端を、押した位置に合わせる。
        // タイムラインではブーストの行でも、スレッドではブーストした人の行がないため、行の上端で合わせると中身が1行分ずれて重なって見える。
        if let cell = collectionView.cellForItem(at: indexPath) {
            frame.origin.y += Self.contextHeight(of: cell)
        }
        let rowTopInView = frame.minY - collectionView.contentOffset.y
        let targetInView = collectionView.convert(CGPoint(x: 0, y: opening.windowY), from: window).y - collectionView.contentOffset.y
        // 押した行の上端がバーの下に隠れていたときは、余白は足さず、同じだけ隠れた位置に置く。
        let extra = max(targetInView - rowTopInView, 0)
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        openingInset = extra
        collectionView.contentInset.top += extra
        updateBottomInset()
        // 余白を足すと、最上部にいるタイムラインはUIKitが位置を合わせ直すため、ずらす量ではなく位置そのものを置く。
        collectionView.contentOffset.y = frame.minY - targetInView
    }

    /// 開くときに足した上の余白を、上に並んだ行で置き換える。上に並んだ行が余白より低いときは、最上部までスプリングで動かして詰める。
    func releaseOpeningInset() {
        guard openingInset > 0 else { return }
        let offset = collectionView.contentOffset.y
        isRestoringAnchor = true
        // 余白を変えると、UIKitが位置を合わせ直すことがあるため、変える前の位置に置き直す。
        collectionView.contentInset.top -= openingInset
        openingInset = 0
        updateBottomInset()
        collectionView.contentOffset.y = offset
        isRestoringAnchor = false
        if offset < topOffset {
            scrollToTop(
                duration: tuning.value(of: TuningCatalog.insertionScrollDuration),
                bounce: tuning.value(of: TuningCatalog.insertionScrollBounce)
            )
        }
    }

    /// `id`の行のすぐ下の行が表示領域の下端より下にあれば、`id`の行を表示領域の上端まで動かし、下の行を見せる。
    func raiseIfNextRowHidden(_ id: ItemID) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return }
        let next = IndexPath(item: indexPath.item + 1, section: indexPath.section)
        guard next.item < collectionView.numberOfItems(inSection: indexPath.section),
              let nextFrame = collectionView.layoutAttributesForItem(at: next)?.frame
        else { return }
        let inset = collectionView.adjustedContentInset
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
        guard nextFrame.minY >= visibleBottom else { return }
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: min(frame.minY - inset.top, maxOffset)), animated: true)
    }

    /// 要素のセル上端を表示領域の上端に合わせる。下に十分な要素がなければ、末尾までスクロールしたところで止める。
    private func scrollToTop(of id: ItemID) {
        restore(ScrollAnchor(id: id, distanceFromVisibleTop: 0))
        let inset = collectionView.adjustedContentInset
        let maxOffset = max(collectionView.contentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        if collectionView.contentOffset.y > maxOffset {
            collectionView.contentOffset.y = maxOffset
        }
    }

    /// 表示領域の外にあっても、指定した要素を基準にする。
    func anchor(of id: ItemID) -> ScrollAnchor? {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return nil }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return ScrollAnchor(id: id, distanceFromVisibleTop: frame.minY - visibleTop)
    }

    /// 表示領域の上端にかかっている行が、使う人の操作によらず描き直され、上端が表示領域の上端より上、下端が表示領域の中にあるなら、その行と今の高さ。
    /// この行の高さが変わったら、上端ではなく下端の位置を保つ。上端を保つと、伸びた分だけ、下の見えている行がすべて動く。下端を保てば、伸びた分は表示領域の上へ出て、下の行は動かない。
    /// 下端が表示領域の下端より下にある行は、表示領域を覆っていて、どちらの端を保てば読んでいる位置が動かないかは、変わった箇所によるため、上端を保つままにする。
    /// 下に、描き直さない見えている行がないときも、上端を保つままにする。
    private func upwardResizingRow(_ ids: Set<ItemID>, among remaining: Set<ItemID>) -> (id: ItemID, height: CGFloat)? {
        guard !ids.isEmpty, let top = currentAnchor(among: remaining), ids.contains(top.id) else { return nil }
        let halfPixel = 0.5 / max(collectionView.traitCollection.displayScale, 1)
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        guard top.distanceFromVisibleTop < -halfPixel,
              let indexPath = dataSource.indexPath(for: top.id), let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
              frame.maxY < visibleBottom
        else { return nil }
        // 下に、描き直さない見えている行がなければ、下端を保っても動かずに済む行がない。設定が変わってすべての行を描き直すときなどで、上端を保つままにする。
        let keepsRowBelow = collectionView.indexPathsForVisibleItems.contains { other in
            guard let id = dataSource.itemIdentifier(for: other), remaining.contains(id), !ids.contains(id),
                  let otherFrame = collectionView.layoutAttributesForItem(at: other)?.frame
            else { return false }
            return otherFrame.minY >= frame.maxY - halfPixel && otherFrame.minY < visibleBottom
        }
        return keepsRowBelow ? (top.id, frame.height) : nil
    }

    /// スナップショットを当て、更新前の基準の要素を同じ位置に戻す。戻した基準を返す。
    /// `anchorID`がないか、表示領域の外にあれば、表示領域の上端にあった要素を基準にする。
    /// 画面外の要素の位置を保つと、その要素と表示領域の間で増えた分だけ、読んでいる行が動くため（ギャップの読み込みを待つ間にギャップを越えて読み進めたときなど）。
    /// - Parameter ids: 中身を描き直す行。上端が表示領域の上端より上にある行が含まれていて、その高さが変わったら、その行の下端を保つ（`upwardResizingRow`）。
    ///   描き直しても高さが変わらなければ、上端を保つ。描き直す行には、高さの変わらない行も入るため（同じ絵文字を使う行など）。
    @discardableResult
    private func applyPreservingAnchor(_ snapshot: NSDiffableDataSourceSnapshot<Section, ItemID>, keeping anchorID: ItemID? = nil, resizing ids: Set<ItemID> = []) -> ScrollAnchor? {
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        // 表示領域の上端にかかっている行が消えるときは、残る行のうち一番上に見えている行を基準にする。
        // 消える行を基準にすると、当て直したあとに位置を合わせる行がなく、読んでいる行が流れるため。指定された行が消えるときも同じにする。
        let remainingAnchorID = anchorID.flatMap { snapshot.indexOfItem($0) != nil && isVisible($0) ? $0 : nil }
        let remaining = Set(snapshot.itemIdentifiers)
        let upward = remainingAnchorID == nil ? upwardResizingRow(ids, among: remaining) : nil
        guard var anchor = remainingAnchorID.flatMap(anchor(of:)) ?? currentAnchor(among: remaining) else {
            FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
            return nil
        }
        FrameWork.measure("snapshot.apply") { dataSource.apply(snapshot, animatingDifferences: false) }
        restore(anchor)
        if let upward, upward.id == anchor.id, let indexPath = dataSource.indexPath(for: upward.id),
           let height = collectionView.layoutAttributesForItem(at: indexPath)?.frame.height, abs(height - upward.height) > 0.5 {
            anchor = ScrollAnchor(id: anchor.id, distanceFromVisibleTop: anchor.distanceFromVisibleTop - (height - upward.height))
            restore(anchor)
        }
        return anchor
    }

    private func isVisible(_ id: ItemID) -> Bool {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return false }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return frame.maxY > visibleTop && frame.minY < visibleBottom
    }

    /// contentOffsetを動かすと、新たに表示されたセルが推定サイズから実サイズへ変わり、基準の位置がまたずれる。
    /// そのため、基準の位置が変わらなくなるまで補正を繰り返す。
    private func restore(_ anchor: ScrollAnchor) {
        for _ in 0..<8 {
            collectionView.layoutIfNeeded()
            guard let indexPath = dataSource.indexPath(for: anchor.id),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return }
            let target = frame.minY - anchor.distanceFromVisibleTop - collectionView.adjustedContentInset.top
            if abs(collectionView.contentOffset.y - target) < 0.01 { return }
            collectionView.contentOffset.y = target
        }
    }
}

extension TimelineViewController: NoticeScreen {
    /// チップの列の上端。この画面の座標。ナビゲーションバーの下に置く。一番上から引っぱっても下げない。
    /// 新着のボタンが出ていてもずらさず、上に重ねる。ボタンは件数の目安で、隠れてもステータスバーやタブから最上部へ戻れるが、
    /// 出たままのチップは、押そうとしている間にボタンの出入りで動くと押せなくなるため。
    var noticeTop: CGFloat {
        view.safeAreaInsets.top + 8
    }

    func noticePlacement(below: CGFloat) -> NoticePlacement {
        NoticePlacement(top: view.convert(CGPoint(x: 0, y: noticeTop), to: nil).y)
    }
}

/// タイムラインのコレクションビュー。本文のリンクを押して少し止めてから引いても、スクロールできるようにする。
final class TimelineCollectionView: UICollectionView {
    /// ほかのアプリからのドロップをタイムラインでは受けず、画面全体の受け口（`MediaDropTarget`）に回して添付する。
    /// コレクションビューは、ドロップのデリゲートがなくても、Macではファイルのドロップを受け付けて何もせずに終える（Macでログを見て確かめた）。
    private let dropDecliner = DropDecliner()

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        dropDelegate = dropDecliner
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 並べ直すたびに、並べ終えたあとで呼ぶ。中で並べ直さずに行の枠を読める。
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        FrameWork.measure("TimelineCollectionView.layoutSubviews") { super.layoutSubviews() }
        onLayout?()
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is LinkHitArea || view is ReadMoreButton || view is PostActionBarButtonView || super.touchesShouldCancel(in: view)
    }
}

/// コレクションビューにドロップを受けさせず、上のビューに回す。
private final class DropDecliner: NSObject, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
        false
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {}
}

extension TimelineViewController: MediaMenuHost {
    /// サムネイルかリンクカードの画像を長押しした。行の要素を探して、メディアのメニューを組む。投稿のメニューは、その「投稿」に入れる。
    func mediaMenu(from view: UIView, at location: CGPoint, groups: MenuLayout<MediaMenuItem>.Groups?) -> BuiltMenu<MediaMenuCommand>? {
        var cellView = view.superview
        while let current = cellView, !(current is UICollectionViewCell) {
            cellView = current.superview
        }
        guard let cell = cellView as? UICollectionViewCell, let indexPath = collectionView.indexPath(for: cell),
              let id = dataSource.itemIdentifier(for: indexPath), let entry = entry(for: id),
              let target = mediaMenuTarget(at: view.convert(location, to: collectionView), in: cell)
        else { return nil }
        return builtMediaMenu(for: target, entry: entry, id: id, groups: groups)
    }

    func mediaMenuWillShow() {
        UserAction.openMenu(screen: texts.dumpName).record()
        menuWillShow()
    }

    func mediaMenuDidHide() {
        menuDidHide()
    }

    /// プレビューの見本では、メディアを押しても何もしない。
    var offersMediaActions: Bool {
        !isAppearancePreview
    }
}

