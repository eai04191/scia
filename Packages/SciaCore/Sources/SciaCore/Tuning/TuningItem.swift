/// 好みで決まる値を、デバッグ用のチューニングパネルから実行中に変えられるようにするための定義。
public enum TuningItem: Sendable, Identifiable {
    case number(NumberTuning)
    case toggle(ToggleTuning)

    public var id: String {
        switch self {
        case .number(let tuning): tuning.id
        case .toggle(let tuning): tuning.id
        }
    }
}

/// チューニングパネルで項目をまとめて見せるカテゴリ。
public struct TuningSection: Sendable, Identifiable {
    /// パネルの開閉状態の保存に使うキー。カテゴリごとに一意にする。
    public let id: String
    public let title: String
    public let items: [TuningItem]

    public init(id: String, title: String, items: [TuningItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// スライダーで調整する数値。
public struct NumberTuning: Sendable, Identifiable {
    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let range: ClosedRange<Double>
    public let step: Double
    public let defaultValue: Double

    public init(id: String, title: String, range: ClosedRange<Double>, step: Double, defaultValue: Double) {
        precondition(range.contains(defaultValue), "\(id)の既定値が範囲外です")
        self.id = id
        self.title = title
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
    }
}

/// スイッチで切り替える真偽値。
public struct ToggleTuning: Sendable, Identifiable {
    /// 保存に使うキー。項目ごとに一意にする。
    public let id: String
    public let title: String
    public let defaultValue: Bool

    public init(id: String, title: String, defaultValue: Bool) {
        self.id = id
        self.title = title
        self.defaultValue = defaultValue
    }
}

/// アプリで使うチューニング項目の一覧。値を足すときは、ここに定義を追加してTuningStoreから読む。
public enum TuningCatalog {
    /// 投稿本文の段落と段落のあいだの余白。
    public static let paragraphSpacing = NumberTuning(
        id: "timeline.paragraphSpacing",
        title: "本文の段落間隔（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 6
    )

    /// 投稿の左に出すアイコンの一辺。
    public static let avatarSize = NumberTuning(
        id: "timeline.avatarSize",
        title: "アイコンの大きさ（pt）",
        range: 24...64,
        step: 2,
        defaultValue: 40
    )

    /// ブーストした人の行に出すアイコンの一辺。
    public static let boosterAvatarSize = NumberTuning(
        id: "timeline.boosterAvatarSize",
        title: "ブーストした人のアイコンの大きさ（pt）",
        range: 12...28,
        step: 1,
        defaultValue: 16
    )

    /// 投稿と通知の行で、左のアイコンの列と、右の文字の列のあいだ。
    public static let avatarSpacing = NumberTuning(
        id: "timeline.avatarSpacing",
        title: "アイコンの列と文字のあいだ（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 10
    )

    /// ブーストや固定、通知の種類を示す名前の上の行と、名前の行のあいだ。
    public static let contextSpacing = NumberTuning(
        id: "timeline.contextSpacing",
        title: "名前の上の行と名前の行のあいだ（pt）",
        range: 0...16,
        step: 1,
        defaultValue: 4
    )

    /// 投稿の名前の行と本文のあいだ。
    public static let nameBodySpacing = NumberTuning(
        id: "timeline.nameBodySpacing",
        title: "名前の行と本文のあいだ（pt）",
        range: 0...16,
        step: 1,
        defaultValue: 5
    )

    /// 投稿の本文と、添付ファイルのサムネイルのあいだ。
    public static let bodyMediaSpacing = NumberTuning(
        id: "timeline.bodyMediaSpacing",
        title: "本文とメディアのあいだ（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 10
    )

    /// 投稿の本文や添付ファイルと、リンクカードのあいだ。
    public static let bodyLinkCardSpacing = NumberTuning(
        id: "timeline.bodyLinkCardSpacing",
        title: "本文とリンクカードのあいだ（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 10
    )

    /// リンクカードの文字の、枠とサムネイルからの余白。
    public static let linkCardPadding = NumberTuning(
        id: "timeline.linkCardPadding",
        title: "リンクカードの内側の余白（pt）",
        range: 0...20,
        step: 1,
        defaultValue: 10
    )

    /// リンク先だけのカードに、サーバーのカードが届いたときの、描き替えのスプリングの時間。画像のないカードでは、サムネイルの枠を縮めて消す。
    public static let linkCardTransitionDuration = NumberTuning(
        id: "timeline.linkCardTransitionDuration",
        title: "リンクカードが届いたときの描き替えの時間（秒）",
        range: 0...1.5,
        step: 0.05,
        defaultValue: 0.4
    )

    /// 注意書き（CW）の箱の内側の余白。
    public static let spoilerPadding = NumberTuning(
        id: "timeline.spoilerPadding",
        title: "注意書きの箱の内側の余白（pt）",
        range: 0...20,
        step: 1,
        defaultValue: 9
    )

    /// 注意書き（CW）の箱と、開いた本文のあいだ。
    public static let spoilerBodySpacing = NumberTuning(
        id: "timeline.spoilerBodySpacing",
        title: "注意書きと本文のあいだ（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 9
    )

    /// 本文のない投稿で、名前の行と、添付ファイルのサムネイルのあいだ。
    public static let nameMediaSpacing = NumberTuning(
        id: "timeline.nameMediaSpacing",
        title: "名前の行とメディアのあいだ（本文なし）（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 12
    )

    /// 添付ファイルのサムネイルを並べるときの、サムネイル同士のすき間。
    public static let mediaTileSpacing = NumberTuning(
        id: "timeline.mediaTileSpacing",
        title: "メディアのサムネイル同士のすき間（pt）",
        range: 0...12,
        step: 1,
        defaultValue: 4
    )

    /// 名前の上の行（ブースト、固定、通知の種類）の記号と、その右の文字やアイコンとのすき間。
    /// 記号はアイコンの列の右端に揃えず、文字の列からこの幅だけ離して置く。記号どうしの縦の揃いは保たれる。
    public static let contextSymbolSpacing = NumberTuning(
        id: "timeline.contextSymbolSpacing",
        title: "名前の上の行の記号と文字のすき間（pt）",
        range: 0...12,
        step: 1,
        defaultValue: 4
    )

    /// 投稿の名前の行が入りきらないときに、行末をぼかす幅。
    public static let nameFadeWidth = NumberTuning(
        id: "timeline.nameFadeWidth",
        title: "名前の行末をぼかす幅（pt）",
        range: 4...60,
        step: 2,
        defaultValue: 20
    )

    /// お気に入りやブーストの通知で、再掲する本文と、1列に並べるサムネイルのあいだ。
    public static let notificationQuotedMediaSpacing = NumberTuning(
        id: "notification.quotedMediaSpacing",
        title: "通知で再掲する本文とサムネイルのあいだ（pt）",
        range: 0...24,
        step: 1,
        defaultValue: 10
    )

    /// フォローなどの通知で、誰が何をしたかの行と、その下に添えるアカウント名のあいだ。
    public static let notificationHeaderDetailSpacing = NumberTuning(
        id: "notification.headerDetailSpacing",
        title: "通知の行とアカウント名のあいだ（pt）",
        range: 0...16,
        step: 1,
        defaultValue: 5
    )

    /// お気に入りやブーストの通知で、誰が何をしたかの行と、再掲する投稿のあいだの余白。
    /// 本文がなく添付ファイルだけの投稿も、同じ余白で添付ファイルを置く。
    public static let notificationQuotedSpacing = NumberTuning(
        id: "notification.quotedSpacing",
        title: "通知で再掲する投稿の上の余白（pt）",
        range: 0...16,
        step: 1,
        defaultValue: 9
    )

    /// お気に入りやブーストの通知で、再掲する投稿の本文を切る行数。誰が何をしたかの行を主役にするため、本文は短く切る。
    public static let notificationQuotedBodyLines = NumberTuning(
        id: "notification.quotedBodyLines",
        title: "通知で再掲する本文の行数",
        range: 1...10,
        step: 1,
        defaultValue: 3
    )

    /// お気に入りやブーストの通知で、再掲する投稿の添付ファイルを1列に並べるサムネイルの一辺。
    /// 行の幅に収まらない分は横にスクロールして見せるため、大きくしても並べられる数は減らない。
    public static let notificationQuotedThumbnailSize = NumberTuning(
        id: "notification.quotedThumbnailSize",
        title: "通知で再掲するサムネイルの大きさ（pt）",
        range: 24...100,
        step: 2,
        defaultValue: 40
    )

    /// ストリーミングで届いた新着を、まとめてタイムラインに挿入する間隔。最初の新着が届いてからこの時間待つ。
    /// 0なら届いたらすぐ挿入する。指で触っている間や長押しのメニューを出している間は、この値によらず操作が終わるまで待つ。
    public static let insertionInterval = NumberTuning(
        id: "streaming.insertionInterval",
        title: "新着をまとめて挿入する間隔（秒）",
        range: 0...10,
        step: 0.1,
        defaultValue: 0
    )

    /// 新着を挿入する前に、新着の行のアイコンが読み込み終わるのを待つ上限。読み込み終われば上限を待たずに挿入する。
    /// 上限を過ぎたら待たずに挿入し、アイコンは届いてから出す。0なら待たない。
    public static let arrivalAvatarWait = NumberTuning(
        id: "streaming.arrivalAvatarWait",
        title: "新着のアイコンを待つ上限（秒）",
        range: 0...2,
        step: 0.05,
        defaultValue: 0.3
    )

    /// 最上部にいるとき、新着を挿入しても最上部に留まり、新着が流れて見えるようにする。
    /// オフなら最上部でも読んでいる位置を保ち、新着件数を出す。
    public static let followsNewArrivalsAtTop = ToggleTuning(
        id: "streaming.followsNewArrivalsAtTop",
        title: "最上部では新着に追従する",
        defaultValue: true
    )

    /// 最上部で新着に追従しているとき、足した行の高さぶん下から最上部へ動かす時間。
    public static let insertionScrollDuration = NumberTuning(
        id: "timeline.insertionScrollDuration",
        title: "新着を挿入して最上部へ動かす時間（秒）",
        range: 0.1...1.5,
        step: 0.05,
        defaultValue: 0.1
    )

    /// 新着を挿入して最上部へ動かすときの弾み。0で行き過ぎずに止まる。
    public static let insertionScrollBounce = NumberTuning(
        id: "timeline.insertionScrollBounce",
        title: "新着を挿入して最上部へ動かす弾み",
        range: 0...0.4,
        step: 0.05,
        defaultValue: 0
    )

    /// 新着ボタン、タブの選び直し、ステータスバーのタップで最上部へ戻る時間。どれだけ離れていても、この時間で戻る。
    public static let scrollToTopDuration = NumberTuning(
        id: "timeline.scrollToTopDuration",
        title: "最上部へ戻る時間（秒）",
        range: 0.1...1.5,
        step: 0.05,
        defaultValue: 0.25
    )

    /// 最上部へ戻るときの弾み。0で行き過ぎずに止まる。
    public static let scrollToTopBounce = NumberTuning(
        id: "timeline.scrollToTopBounce",
        title: "最上部へ戻る弾み",
        range: 0...0.4,
        step: 0.05,
        defaultValue: 0
    )

    /// つなぎ直したとき、切れていた間の投稿を手元とつながるまで続けて読むページ数の上限。1ページは40件。
    /// 超えた分はギャップとして残り、近づいたときに読む。
    public static let fillPageLimit = NumberTuning(
        id: "streaming.fillPageLimit",
        title: "再接続で続けて読むページ数",
        range: 1...10,
        step: 1,
        defaultValue: 5
    )

    /// ストリーミングにつながらない間、切れていた間の新着をRESTで読む間隔。つなぎ直しはその間も続ける。
    public static let pollingInterval = NumberTuning(
        id: "streaming.pollingInterval",
        title: "つながらない間に新着を読む間隔（秒）",
        range: 15...300,
        step: 15,
        defaultValue: 60
    )

    /// 補完の読み込みに、サーバーがホームを作り直している最中だと返されたとき、読み直すまでの間隔。
    /// 作り直しが終わるまで、この間隔で読み直し続ける。
    public static let regeneratingRetryInterval = NumberTuning(
        id: "streaming.regeneratingRetryInterval",
        title: "ホームの作り直し中に読み直す間隔（秒）",
        range: 5...120,
        step: 5,
        defaultValue: 10
    )

    /// ストリーミングにつながらない状態がこれだけ続いたら、ナビゲーションバーで知らせる。短い切断のたびには知らせない。
    public static let outageNoticeDelay = NumberTuning(
        id: "streaming.outageNoticeDelay",
        title: "切れていると知らせるまでの時間（秒）",
        range: 0...120,
        step: 5,
        defaultValue: 30
    )

    /// ギャップが表示領域からこの距離（画面の高さの何倍か）まで近づいたら、タップを待たずに読み始める。
    public static let gapAutoLoadDistance = NumberTuning(
        id: "timeline.gapAutoLoadDistance",
        title: "ギャップを自動で読む距離（画面数）",
        range: 0...3,
        step: 0.5,
        defaultValue: 1
    )

    /// 添付ファイルが1つの投稿で、縦長の画像をどこまで縦長のまま出すか（幅÷高さ）。これより縦長なものは上下を切り落とす。
    public static let mediaTallestAspectRatio = NumberTuning(
        id: "timeline.mediaTallestAspectRatio",
        title: "1枚の画像の最も縦長な比率（幅÷高さ）",
        range: 0.5...1.5,
        step: 0.05,
        defaultValue: 0.75
    )

    /// 一覧のサムネイルで、サーバーが縮めたプレビュー画像を何倍まで引き伸ばして出してよいか。超えるなら元の画像を読む。
    /// 大きくするほど通信量は減るが、ぼやける。
    public static let mediaThumbnailUpscaleTolerance = NumberTuning(
        id: "timeline.mediaThumbnailUpscaleTolerance",
        title: "サムネイルのプレビュー画像を引き伸ばしてよい倍率",
        range: 1...3,
        step: 0.1,
        defaultValue: 1
    )

    /// ビューアを下へのスワイプで閉じる距離。画面の高さに対する割合。
    public static let mediaDismissDistance = NumberTuning(
        id: "media.dismissDistance",
        title: "ビューアを閉じる距離（画面の高さの割合）",
        range: 0.05...0.5,
        step: 0.01,
        defaultValue: 0.12
    )

    /// ビューアを下へのスワイプで閉じる速さ。毎秒何画面ぶんか。これより速くスワイプすれば、短い距離でも閉じる。
    public static let mediaDismissVelocity = NumberTuning(
        id: "media.dismissVelocity",
        title: "ビューアを閉じるスワイプの速さ（画面数／秒）",
        range: 0.2...3,
        step: 0.1,
        defaultValue: 0.8
    )

    /// ビューアを下へスワイプしている間、画面の高さぶん動かしたときの画像の倍率。
    public static let mediaDismissSmallestScale = NumberTuning(
        id: "media.dismissSmallestScale",
        title: "閉じる操作中に縮める倍率",
        range: 0.3...1,
        step: 0.05,
        defaultValue: 0.6
    )

    /// ビューアを下へスワイプしている間、背景が透けきるまでに動かす距離。画面の高さに対する割合。
    public static let mediaDismissFadeDistance = NumberTuning(
        id: "media.dismissFadeDistance",
        title: "閉じる操作中に背景が透けきる距離（画面の高さの割合）",
        range: 0.1...1,
        step: 0.05,
        defaultValue: 0.5
    )

    /// ビューアを閉じずに離したとき、画像を元の位置へ戻す時間。
    public static let mediaDismissRestoreDuration = NumberTuning(
        id: "media.dismissRestoreDuration",
        title: "閉じずに離したとき戻す時間（秒）",
        range: 0.1...1,
        step: 0.05,
        defaultValue: 0.35
    )

    /// ビューアを開くとき、サムネイルから広げてビューアで表示し終えるまでの時間。
    public static let mediaOpenDuration = NumberTuning(
        id: "media.openDuration",
        title: "ビューアを開く時間（秒）",
        range: 0.1...1,
        step: 0.05,
        defaultValue: 0.2
    )

    /// ビューアを閉じるとき、サムネイルへ縮めて戻すまでの時間。
    public static let mediaCloseDuration = NumberTuning(
        id: "media.closeDuration",
        title: "ビューアを閉じる時間（秒）",
        range: 0.1...1,
        step: 0.05,
        defaultValue: 0.2
    )

    /// ビューアを下へスワイプして閉じるときの弾み。0で行き過ぎずに止まる。
    /// 指で力を加えたときだけ弾ませ、タップで開くときや、ボタンで閉じるときは弾ませない。
    public static let mediaDragCloseBounce = NumberTuning(
        id: "media.dragCloseBounce",
        title: "ビューアをスワイプして閉じるときの弾み",
        range: 0...0.4,
        step: 0.05,
        defaultValue: 0.1
    )

    /// ビューアを開閉するとき、画像のうちバーにかかる部分を、バーの奥にも描く。
    /// オフなら、開くときは複製をバーの手前にだけ描き、閉じるときはバーにかかる部分を着地へ近づくにつれて切り落とすだけにする。
    /// 開き始めにバーの下のサムネイルがバーの手前へ急に出て、閉じる着地の瞬間にバー越しのサムネイルが急に現れる。
    public static let mediaCloseDrawsUnderBars = ToggleTuning(
        id: "media.closeDrawsUnderBars",
        title: "ビューアを開閉するとき、バーにかかる部分をバーの奥に描く",
        defaultValue: true
    )

    /// バーの奥にも描くとき、一覧の中の複製から最前面の複製へ受け渡し終える、開く動きの進み具合。0なら開き始めから最前面の複製にする。
    public static let mediaOpenHandoffEnd = NumberTuning(
        id: "media.openHandoffEnd",
        title: "開くとき、一覧の中の複製から受け渡し終える進み具合",
        range: 0...1,
        step: 0.05,
        defaultValue: 0.3
    )

    /// バーの奥にも描くとき、バーと重なる部分を一覧の中の複製からバーより手前の複製へ入れ替え始める、開く動きの進み具合。
    /// 小さいほど早くバーの手前の見え方になり、大きいほど画像がバーの奥に長く残る。
    public static let mediaOpenBarOverlapFadeStart = NumberTuning(
        id: "media.openBarOverlapFadeStart",
        title: "開くとき、バーと重なる部分を手前へ入れ替え始める進み具合",
        range: 0...0.95,
        step: 0.05,
        defaultValue: 0.7
    )

    /// バーの奥にも描くとき、最前面の複製を薄くして一覧の中の複製へ受け渡し始める、閉じる動きの進み具合。1なら着地の瞬間に切り替える。
    /// 一覧の中の複製には、バーの下のぼかしや一覧に重なるボタンが正しくかかる。受け渡しが遅いほど、着地でそれらが急に現れる。
    public static let mediaCloseHandoffStart = NumberTuning(
        id: "media.closeHandoffStart",
        title: "閉じるとき、一覧の中の複製へ受け渡し始める進み具合",
        range: 0...1,
        step: 0.05,
        defaultValue: 0.7
    )

    /// バーの奥にも描くとき、閉じ始めにバーと重なっていた部分（縦長の画像や、下へスワイプしてタブバーにかかった画像）を、
    /// バーより手前の複製から一覧の中の複製へ入れ替え終える、閉じる動きの進み具合。
    /// 小さいほど早くバーの奥の見え方になり、大きいほど閉じ始めの画像の端がバーの位置で長く手前に残る。
    public static let mediaCloseBarOverlapFadeEnd = NumberTuning(
        id: "media.closeBarOverlapFadeEnd",
        title: "閉じるとき、バーと重なっていた部分を奥へ入れ替え終える進み具合",
        range: 0.05...1,
        step: 0.05,
        defaultValue: 0.3
    )

    /// ビューアのメニューから写真に保存したときや、投稿のリンクをコピーしたとき、済んだことを知らせる表示を出しておく時間。
    public static let mediaSavedChipDuration = NumberTuning(
        id: "media.savedChipDuration",
        title: "保存やコピーを知らせる表示を出しておく時間（秒）",
        range: 0.5...4,
        step: 0.1,
        defaultValue: 1.5
    )

    /// 知らせのチップ（写真に保存しました、ダウンロード中など）が出入りし、並びを詰め直す時間。
    public static let noticeAnimationDuration = NumberTuning(
        id: "notice.animationDuration",
        title: "知らせのチップの出入りの時間（秒）",
        range: 0.05...2,
        step: 0.05,
        defaultValue: 0.2
    )

    /// お気に入りやブーストの失敗など、押し直せば済む失敗を知らせるチップを出しておく時間。指が触れている間は数えない。
    public static let noticeFailureChipDuration = NumberTuning(
        id: "notice.failureChipDuration",
        title: "失敗を知らせるチップを出しておく時間（秒）",
        range: 1...10,
        step: 0.5,
        defaultValue: 4
    )

    /// 動画を再生している間、最後に触れてから操作の部品とボタンを隠すまでの時間。
    public static let mediaVideoControlsHideDelay = NumberTuning(
        id: "media.videoControlsHideDelay",
        title: "再生中に操作の部品を隠すまでの時間（秒）",
        range: 1...10,
        step: 0.5,
        defaultValue: 3
    )

    /// 動画をダブルタップして10秒戻ったか進んだことを知らせる表示を、出しておく時間。
    public static let mediaVideoSkipEffectDuration = NumberTuning(
        id: "media.videoSkipEffectDuration",
        title: "ダブルタップで飛んだ知らせを出しておく時間（秒）",
        range: 0.1...1.5,
        step: 0.05,
        defaultValue: 0.3
    )

    /// 代替テキストを書いているとき、残りの文字数がこれ以下になったら残りを出す。
    public static let mediaDescriptionRemainingThreshold = NumberTuning(
        id: "media.descriptionRemainingThreshold",
        title: "代替テキストの残りの文字数を出し始める数",
        range: 0...1500,
        step: 10,
        defaultValue: 100
    )

    /// 代替テキストの入力欄を、書いた分だけ伸ばす最大の行数。超えたら伸ばさずに中でスクロールする。
    public static let mediaDescriptionMaxLines = NumberTuning(
        id: "media.descriptionMaxLines",
        title: "代替テキストの入力欄の最大の行数",
        range: 1...12,
        step: 1,
        defaultValue: 6
    )

    /// 書いていないときの投稿欄の高さ（pt）。細いほど一覧の閲覧を邪魔しない。
    public static let composeRestingHeight = NumberTuning(
        id: "compose.restingHeight",
        title: "書いていないときの投稿欄の高さ（pt）",
        range: 32...56,
        step: 1,
        defaultValue: 40
    )

    /// 本文のリンクを開くアプリ内のSafariの、全画面でないときのシートの高さ。シートが取れる最大の高さに対する割合。
    /// 0.5でシステムの中くらいの高さとほぼ同じになる。シートを出したまま、上に一覧を見る高さ。
    public static let inAppBrowserMediumFraction = NumberTuning(
        id: "browser.mediumFraction",
        title: "アプリ内のSafariのシートの高さ（割合）",
        range: 0.25...0.85,
        step: 0.05,
        defaultValue: 0.5
    )

    /// アプリ内のSafariのシートをいちばん下げたときの高さ（pt、下の安全領域を除く）。投稿欄で書いている間はこの高さまで下げる。
    /// 一時的に伏せておくために、つまみで下げることもできる。中くらいの高さで一覧をスクロールする指がシートを引き下ろしても、
    /// いったんこの高さで止まるため、閉じにくくする役も持つ。
    public static let inAppBrowserCollapsedHeight = NumberTuning(
        id: "browser.collapsedHeight",
        title: "アプリ内のSafariを伏せたときの高さ（pt）",
        range: 40...200,
        step: 4,
        defaultValue: 120
    )

    /// アプリ内のSafariを、伏せた高さで出してから中くらいの高さへ広げる。
    /// 実機では、中くらいの高さで直接出すと、ページを描く前の面が上がってきて、手前で本物のシートに跳んで止まって見える。
    /// 小さく出して上がりきってから広げると、広げる動きはページを描いたシートで動き、跳ぶ動きが目立ちにくくなる。実機で比べて、こちらを既定にした。
    public static let inAppBrowserGrowsFromCollapsed = ToggleTuning(
        id: "browser.growsFromCollapsed",
        title: "アプリ内のSafariを伏せた高さから広げて出す",
        defaultValue: true
    )

    /// 投稿欄が、細いカプセルと書くときの形の間で形を変える時間（秒）。位置の動きはキーボードに合わせて別に動く。
    public static let composeMorphDuration = NumberTuning(
        id: "compose.morphDuration",
        title: "投稿欄が形を変える時間（秒）",
        range: 0.05...1.5,
        step: 0.05,
        defaultValue: 0.35
    )

    /// 投稿欄を展開ボタンで安全領域の上端まで広げる時間と、5行の高さに戻す時間（秒）。
    public static let composeExpandDuration = NumberTuning(
        id: "compose.expandDuration",
        title: "投稿欄を広げる・戻す時間（秒）",
        range: 0.05...1.5,
        step: 0.05,
        defaultValue: 0.35
    )

    /// メディアを選ぶシートの低いときの高さを、最後に出したキーボードの高さに合わせる。
    /// 切ると、キーボードを一度も出していないときと同じく、決めた高さで出す。
    public static let composePickerMatchesKeyboard = ToggleTuning(
        id: "compose.pickerMatchesKeyboard",
        title: "メディアを選ぶシートをキーボードの高さに合わせる",
        defaultValue: true
    )

    /// メディアを選ぶシートの低いときの、画面の下端からの高さ（pt）。キーボードの高さが分からないときや、合わせないときに使う。
    /// キーボードの高さは日本語入力の候補の段や他社のキーボードで変わり、ハードウェアキーボードでは0になる。
    public static let composePickerHeight = NumberTuning(
        id: "compose.pickerHeight",
        title: "メディアを選ぶシートの決めた高さ（pt）",
        range: 200...500,
        step: 2,
        defaultValue: 336
    )

    /// メンションとハッシュタグの補完で、打つのが止まってから問い合わせるまでの時間（秒）。
    public static let completionDebounce = NumberTuning(
        id: "compose.completion.debounce",
        title: "補完：問い合わせまでの待ち（秒）",
        range: 0...1,
        step: 0.05,
        defaultValue: 0.15
    )

    /// 補完の候補を出す数。
    public static let completionLimit = NumberTuning(
        id: "compose.completion.limit",
        title: "補完：候補の数",
        range: 1...10,
        step: 1,
        defaultValue: 5
    )

    /// メンションとハッシュタグで、印のあとに何文字打ったら候補を出すか。
    /// web UIと同じく2文字にする。1文字で問い合わせると、stellaria.networkのアカウント検索は500を返した（2026年10月）。
    public static let completionMinimumQuery = NumberTuning(
        id: "compose.completion.minimumQuery",
        title: "補完：メンションとタグを出す文字数",
        range: 1...4,
        step: 1,
        defaultValue: 2
    )

    /// カスタム絵文字で、`:`のあとに何文字打ったら候補を出すか。一覧は手元にあり問い合わせないので、少なくてよい。
    /// 0にすると、「例:」のように日本語のすぐ後に`:`を打つたびに一覧が出るため、既定は1にする。
    public static let completionEmojiMinimumQuery = NumberTuning(
        id: "compose.completion.emojiMinimumQuery",
        title: "補完：絵文字を出す文字数",
        range: 0...4,
        step: 1,
        defaultValue: 1
    )

    /// 補完の候補の一覧を出し入れする時間（秒）。
    public static let completionFadeDuration = NumberTuning(
        id: "compose.completion.fadeDuration",
        title: "補完：一覧の出入りの時間（秒）",
        range: 0...0.6,
        step: 0.02,
        defaultValue: 0.12
    )

    @MainActor
    public static func completionSettings(in store: TuningStore) -> ComposeCompletion.Settings {
        ComposeCompletion.Settings(
            debounce: .milliseconds(Int(store.value(of: completionDebounce) * 1000)),
            limit: Int(store.value(of: completionLimit))
        )
    }

    @MainActor
    public static func completionMinimumQueryLength(in store: TuningStore) -> [CompletionKind: Int] {
        let mentionAndTag = Int(store.value(of: completionMinimumQuery))
        return [.mention: mentionAndTag, .hashtag: mentionAndTag, .emoji: Int(store.value(of: completionEmojiMinimumQuery))]
    }

    /// ストリーミングにつながらない間の、ポーリングと知らせるまでの時間。
    @MainActor
    public static func liveUpdates(in store: TuningStore) -> LiveUpdates.Policy {
        LiveUpdates.Policy(
            pollingInterval: .seconds(store.value(of: pollingInterval)),
            outageNoticeDelay: .seconds(store.value(of: outageNoticeDelay))
        )
    }

    /// ビューアの閉じる操作の判定。
    @MainActor
    public static func dragToDismiss(in store: TuningStore) -> DragToDismiss {
        DragToDismiss(
            distanceThreshold: store.value(of: mediaDismissDistance),
            velocityThreshold: store.value(of: mediaDismissVelocity),
            smallestScale: store.value(of: mediaDismissSmallestScale),
            fadeDistance: store.value(of: mediaDismissFadeDistance),
            restoreDuration: store.value(of: mediaDismissRestoreDuration)
        )
    }

    public static let sections: [TuningSection] = [
        TuningSection(id: "timeline", title: "タイムラインの見た目", items: [
            .number(paragraphSpacing),
            .number(avatarSize),
            .number(boosterAvatarSize),
            .number(contextSymbolSpacing),
            .number(avatarSpacing),
            .number(contextSpacing),
            .number(nameBodySpacing),
            .number(bodyMediaSpacing),
            .number(nameMediaSpacing),
            .number(bodyLinkCardSpacing),
            .number(linkCardPadding),
            .number(linkCardTransitionDuration),
            .number(spoilerPadding),
            .number(spoilerBodySpacing),
            .number(mediaTileSpacing),
            .number(nameFadeWidth),
            .number(mediaTallestAspectRatio),
            .number(mediaThumbnailUpscaleTolerance),
        ]),
        TuningSection(id: "notification", title: "通知の見た目", items: [
            .number(notificationQuotedSpacing),
            .number(notificationQuotedMediaSpacing),
            .number(notificationHeaderDetailSpacing),
            .number(notificationQuotedBodyLines),
            .number(notificationQuotedThumbnailSize),
        ]),
        TuningSection(id: "timeline.motion", title: "タイムラインの動き", items: [
            .number(scrollToTopDuration),
            .number(scrollToTopBounce),
            .number(insertionScrollDuration),
            .number(insertionScrollBounce),
        ]),
        TuningSection(id: "streaming", title: "新着と読み込み", items: [
            .number(insertionInterval),
            .number(arrivalAvatarWait),
            .toggle(followsNewArrivalsAtTop),
            .number(fillPageLimit),
            .number(gapAutoLoadDistance),
            .number(pollingInterval),
            .number(regeneratingRetryInterval),
            .number(outageNoticeDelay),
        ]),
        TuningSection(id: "compose", title: "投稿欄", items: [
            .number(composeRestingHeight),
            .number(composeMorphDuration),
            .number(composeExpandDuration),
            .toggle(composePickerMatchesKeyboard),
            .number(composePickerHeight),
            .number(completionDebounce),
            .number(completionLimit),
            .number(completionMinimumQuery),
            .number(completionEmojiMinimumQuery),
            .number(completionFadeDuration),
        ]),
        TuningSection(id: "browser", title: "アプリ内のSafari", items: [
            .number(inAppBrowserMediumFraction),
            .number(inAppBrowserCollapsedHeight),
            .toggle(inAppBrowserGrowsFromCollapsed),
        ]),
        TuningSection(id: "media.dismiss", title: "ビューア：閉じる操作", items: [
            .number(mediaDismissDistance),
            .number(mediaDismissVelocity),
            .number(mediaDismissSmallestScale),
            .number(mediaDismissFadeDistance),
            .number(mediaDismissRestoreDuration),
        ]),
        TuningSection(id: "media.transition", title: "ビューア：開閉の動き", items: [
            .number(mediaOpenDuration),
            .number(mediaCloseDuration),
            .number(mediaDragCloseBounce),
        ]),
        TuningSection(id: "media.bars", title: "ビューア：バーとの重なり", items: [
            .toggle(mediaCloseDrawsUnderBars),
            .number(mediaOpenHandoffEnd),
            .number(mediaOpenBarOverlapFadeStart),
            .number(mediaCloseHandoffStart),
            .number(mediaCloseBarOverlapFadeEnd),
        ]),
        TuningSection(id: "media.menu", title: "ビューア：メニュー", items: [
            .number(mediaSavedChipDuration),
        ]),
        TuningSection(id: "notice", title: "知らせ", items: [
            .number(noticeAnimationDuration),
            .number(noticeFailureChipDuration),
        ]),
        TuningSection(id: "media.video", title: "ビューア：動画", items: [
            .number(mediaVideoControlsHideDelay),
            .number(mediaVideoSkipEffectDuration),
        ]),
        TuningSection(id: "media.description", title: "ビューア：代替テキスト", items: [
            .number(mediaDescriptionRemainingThreshold),
            .number(mediaDescriptionMaxLines),
        ]),
    ]
}
