/// 添付ファイルを、使う人が開いたり隠したりする前に、ぼかすかどうか。
/// 値はMastodonのアカウントの設定「メディアの表示」（`reading:expand:media`）と同じ。
/// https://docs.joinmastodon.org/methods/preferences/
public enum MediaDisplay: String, CaseIterable, Codable, Sendable {
    /// 閲覧注意か注意書きのある投稿だけぼかす。
    case hidesSensitive = "default"
    /// 閲覧注意でもぼかさない。
    case showsAll = "show_all"
    /// 閲覧注意でなくてもぼかす。
    case hidesAll = "hide_all"

    /// 使う人が選んでいない投稿の添付ファイルをぼかすか。
    /// - Parameter isSensitive: 閲覧注意か注意書きがある。
    public func covers(isSensitive: Bool) -> Bool {
        switch self {
        case .hidesSensitive: isSensitive
        case .showsAll: false
        case .hidesAll: true
        }
    }

    /// 設定の選択肢と、アカウントの画面に出す値の名前。
    public var title: String {
        switch self {
        case .hidesSensitive: "閲覧注意だけ隠す"
        case .showsAll: "常に表示"
        case .hidesAll: "常に隠す"
        }
    }
}
