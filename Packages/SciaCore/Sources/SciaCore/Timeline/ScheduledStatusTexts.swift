/// 予約投稿の画面に出す文言。
public enum ScheduledStatusTexts {
    public static let title = "予約投稿"
    /// 行の操作の名前。メニュー、スワイプ、VoiceOverの操作で同じ名前にする。
    public static let reschedule = "日時を変える"
    public static let rewrite = "投稿欄に戻して書き直す"
    public static let cancel = "取り消す"
    /// 行を押すと日時を変えることの、読み上げのヒント。
    public static let rescheduleHint = "日時を変えます。"

    public static let loadFailure = "読み込めませんでした"
    public static let reload = "再読み込み"
    public static let empty = "予約した投稿はありません"

    /// 日時を変えるシートの題と、決めるボタン。
    public static let rescheduleSheetTitle = "予約の日時を変える"
    public static let rescheduleConfirm = "変更"
    /// 選んでから決めるまでの間に、予約の日時が今から5分を切ったときの理由。
    public static let tooSoon = "予約の日時は今から5分より後にしてください。"

    /// 名前の上の行に書く、予約の中身の種類。
    public enum ContextPart: Sendable {
        case reply
        case quote
        case poll

        public var title: String {
            switch self {
            case .reply: "返信"
            case .quote: "引用"
            case .poll: "投票"
            }
        }
    }

    /// 名前の上の行の文。返信、引用、投票の予約なら、そのことを並べて書く。
    public static func context(_ parts: [ContextPart]) -> String {
        parts.map(\.title).joined(separator: "・")
    }
}

extension ScheduledStatusesModel.Operation {
    /// 失敗の見出し。
    public var failureTitle: String {
        switch self {
        case .reschedule: "日時を変更できませんでした"
        case .cancel: "予約を取り消せませんでした"
        }
    }
}
