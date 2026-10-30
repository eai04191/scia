/// 操作の結果や処理の途中を知らせるチップの中身。出方の決まりはdocs/notices.mdの「チップ」にある。
///
/// 数秒で消えるか出たままかは中身に持たせず、`NoticeStackView`のどちらに渡すかで決める。消え方と押せるかを別々に選べるようにするため。
public struct Notice: Sendable {
    /// アプリ内通知の種類。先頭のアイコンと、ボタン類を隠したときに一緒に隠すかを決める。
    public enum Kind: Equatable, Sendable {
        /// 処理の途中。済めば消えるため、ボタン類を隠しても隠さない。
        case progress
        /// 済んだこと。
        case success
        /// 失敗。出たままのものは使う人が対処するまで残るため、ボタン類と一緒に隠す。
        case failure
        /// 成功でも失敗でもない、起きたことの知らせ。ビューアを閉じたので共有を止めたなど。アイコンを付けない。
        case info
    }

    /// 押したときに起きること。
    public enum Action: Sendable {
        /// 押せない。末尾の記号を付けない。
        case none
        /// 押すと続き（理由と再試行、止めるかの確認など）が出る。末尾に「›」を付ける。
        /// - Parameter hint: VoiceOverで、押すと何が起きるかを伝える文。
        case disclosure(hint: String, handler: @MainActor () -> Void)
        /// 押すとすぐ実行される。何が起きるかは文言で示し、末尾の記号は付けない。
        case immediate(hint: String, handler: @MainActor () -> Void)
    }

    /// 同じ知らせかを見分ける。文言や進み具合が変わっても同じ値にする。
    public var id: String
    public var kind: Kind
    public var title: String
    /// 文言のあとに添える、数字の幅をそろえて描く値（進み具合など）。変わっても読み上げ直さない。
    public var value: String?
    /// 同時に出たままになっている、ほかの知らせの数。1以上なら、場所を取らないよう「+n件」と添える。VoiceOverでは「ほかにn件」と読む。
    public var additionalCount = 0
    public var action: Action = .none
    /// `value`が進み具合か。進み具合が変わっただけなら、上へスワイプしてしまったチップをまた出さない。件数や縮めた大きさなど、ほかの値は中身として扱う。
    public var valueIsProgress = false

    public init(id: String, kind: Kind, title: String, value: String? = nil, additionalCount: Int = 0, action: Action = .none, valueIsProgress: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.value = value
        self.additionalCount = additionalCount
        self.action = action
        self.valueIsProgress = valueIsProgress
    }

    /// 画面に出す文言。添える件数と「›」は含まない。
    public var text: String {
        value.map { "\(title) \($0)" } ?? title
    }

    public var isActionable: Bool {
        if case .none = action { false } else { true }
    }

    /// 画面に出したときに同じ見た目で、VoiceOverでも同じに伝わるか。押したときの処理は比べない。
    public func looksSame(as other: Notice) -> Bool {
        id == other.id && kind == other.kind && title == other.title && value == other.value
            && additionalCount == other.additionalCount && actionHint == other.actionHint
    }

    private var actionHint: String? {
        switch action {
        case .none: nil
        case .disclosure(let hint, _): "disclosure:\(hint)"
        case .immediate(let hint, _): "immediate:\(hint)"
        }
    }
}
