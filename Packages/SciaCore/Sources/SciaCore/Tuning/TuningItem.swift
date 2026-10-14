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

    /// ストリーミングで届いた新着を、まとめてタイムラインに挿入する間隔。最初の新着が届いてからこの時間待つ。
    public static let insertionInterval = NumberTuning(
        id: "streaming.insertionInterval",
        title: "新着をまとめて挿入する間隔（秒）",
        range: 0...10,
        step: 0.5,
        defaultValue: 1
    )

    /// 最上部にいるとき、新着を挿入しても最上部に留まり、新着が流れて見えるようにする。
    /// オフなら最上部でも読んでいる位置を保ち、新着件数を出す。
    public static let followsNewArrivalsAtTop = ToggleTuning(
        id: "streaming.followsNewArrivalsAtTop",
        title: "最上部では新着に追従する",
        defaultValue: true
    )

    /// 最上部で新着に追従しているとき、新着をUIKit標準のアニメーションで挿入する。オフなら一度に差し替える。
    /// 最上部より下で読んでいるときは、読んでいる位置を保つため、この値によらずアニメーションしない。
    public static let animatesInsertionAtTop = ToggleTuning(
        id: "streaming.animatesInsertionAtTop",
        title: "最上部では新着をアニメーションで挿入する",
        defaultValue: true
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

    /// ビューアを下へのスワイプで閉じる距離。画面の高さに対する割合。
    public static let mediaDismissDistance = NumberTuning(
        id: "media.dismissDistance",
        title: "ビューアを閉じる距離（画面の高さの割合）",
        range: 0.05...0.5,
        step: 0.01,
        defaultValue: 0.12
    )

    /// ビューアを下へのスワイプで閉じる速さ。毎秒何画面ぶんか。これより速く払えば、短い距離でも閉じる。
    public static let mediaDismissVelocity = NumberTuning(
        id: "media.dismissVelocity",
        title: "ビューアを閉じる払う速さ（画面数／秒）",
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
        defaultValue: 0.4
    )

    /// ビューアを閉じるとき、サムネイルへ縮めて戻すまでの時間。
    public static let mediaCloseDuration = NumberTuning(
        id: "media.closeDuration",
        title: "ビューアを閉じる時間（秒）",
        range: 0.1...1,
        step: 0.05,
        defaultValue: 0.4
    )

    /// ビューアを開閉するときの弾み。0で行き過ぎずに止まる。
    public static let mediaTransitionBounce = NumberTuning(
        id: "media.transitionBounce",
        title: "ビューアの開閉の弾み",
        range: 0...0.4,
        step: 0.05,
        defaultValue: 0.1
    )

    /// ビューアを閉じるとき、戻る画像のうちバーにかかる部分を、バーの奥にも描く。
    /// オフなら、バーにかかる部分を着地へ近づくにつれて切り落とすだけにする。着地の瞬間に、バー越しのサムネイルが急に現れる。
    public static let mediaCloseDrawsUnderBars = ToggleTuning(
        id: "media.closeDrawsUnderBars",
        title: "ビューアを閉じるとき、バーにかかる部分をバーの奥に描く",
        defaultValue: true
    )

    /// バーの奥にも描くとき、最前面の写しを薄くして一覧の中の写しへ受け渡し始める、閉じる動きの進み具合。1なら着地の瞬間に切り替える。
    /// 一覧の中の写しには、バーの下のぼかしや一覧に重なるボタンが正しくかかる。受け渡しが遅いほど、着地でそれらが急に現れる。
    public static let mediaCloseHandoffStart = NumberTuning(
        id: "media.closeHandoffStart",
        title: "閉じるとき、一覧の中の写しへ受け渡し始める進み具合",
        range: 0...1,
        step: 0.05,
        defaultValue: 0.7
    )

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

    public static let items: [TuningItem] = [
        .number(paragraphSpacing),
        .number(insertionInterval),
        .toggle(followsNewArrivalsAtTop),
        .toggle(animatesInsertionAtTop),
        .number(fillPageLimit),
        .number(gapAutoLoadDistance),
        .number(mediaTallestAspectRatio),
        .number(mediaDismissDistance),
        .number(mediaDismissVelocity),
        .number(mediaDismissSmallestScale),
        .number(mediaDismissFadeDistance),
        .number(mediaDismissRestoreDuration),
        .number(mediaOpenDuration),
        .number(mediaCloseDuration),
        .number(mediaTransitionBounce),
        .toggle(mediaCloseDrawsUnderBars),
        .number(mediaCloseHandoffStart),
    ]
}
