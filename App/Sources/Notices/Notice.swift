import Foundation

/// 操作の結果や処理の途中を知らせるチップの中身。出方の決まりはdocs/notices.mdの「チップ」にある。
///
/// 数秒で消えるか出たままかは中身に持たせず、`NoticeStackView`のどちらに渡すかで決める。消え方と押せるかを別々に選べるようにするため。
struct Notice {
    /// 知らせの種類。先頭の印と、ボタン類を隠したときに一緒に隠すかを決める。
    enum Kind: Equatable {
        /// 処理の途中。済めば消えるため、ボタン類を隠しても隠さない。
        case progress
        /// 済んだこと。
        case success
        /// 失敗。出たままのものは使う人が対処するまで残るため、ボタン類と一緒に隠す。
        case failure
        /// 成功でも失敗でもない、起きたことの知らせ。ビューアを閉じたので共有を止めたなど。印を付けない。
        case info
    }

    /// 押したときに起きること。
    enum Action {
        /// 押せない。印を付けない。
        case none
        /// 押すと続き（理由と再試行、止めるかの確認など）が出る。末尾に「›」を付ける。
        /// - Parameter hint: VoiceOverで、押すと何が起きるかを伝える文。
        case disclosure(hint: String, handler: @MainActor () -> Void)
        /// 押すとすぐ実行される。何が起きるかは文言で示し、印は付けない。
        case immediate(hint: String, handler: @MainActor () -> Void)
    }

    /// 同じ知らせかを見分ける。文言や進み具合が変わっても同じ値にする。
    var id: String
    var kind: Kind
    var title: String
    /// 文言のあとに添える、数字の幅をそろえて描く値（進み具合など）。変わっても読み上げ直さない。
    var value: String?
    /// 同時に出たままになっている、ほかの知らせの数。1以上なら、場所を取らないよう「+n件」と添える。VoiceOverでは「ほかにn件」と読む。
    var additionalCount = 0
    var action: Action = .none

    /// 画面に出す文言。添える件数と「›」は含まない。
    var text: String {
        value.map { "\(title) \($0)" } ?? title
    }

    var isActionable: Bool {
        if case .none = action { false } else { true }
    }
}
