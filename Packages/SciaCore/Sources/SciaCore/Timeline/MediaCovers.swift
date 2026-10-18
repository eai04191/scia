/// 一覧で添付ファイルを覆う理由。覆いに出す文言を分ける。
public enum MediaCover: Sendable, Equatable {
    /// 投稿者が閲覧注意か注意書きを付けた。
    case sensitive
    /// 閲覧注意のない投稿を、使う人が隠した。
    case hidden
}

/// 一覧で投稿の添付ファイルを覆うか。
///
/// 閲覧注意と注意書きのある投稿は最初から覆う。使う人が開いたり隠したりした投稿は、閲覧注意かどうかにかかわらずその選択に従う。
/// 選択は元の投稿のIDで覚え、同じ投稿のブーストや通知の行もそろえる。覚えるのはアプリを起動している間だけ。
public struct MediaCovers: Sendable, Equatable {
    /// 投稿ごとに、覆うと選んだか。
    private var choices: [Status.ID: Bool] = [:]

    public init() {}

    /// 覆っていればその理由、覆っていなければnil。ブーストなら元の投稿で決める。
    /// 開いたあとに隠した閲覧注意の投稿は、開く前と同じく`.sensitive`にする。
    public func cover(for status: Status) -> MediaCover? {
        let shown = status.displayed
        let isSensitive = shown.sensitive || !shown.spoilerText.isEmpty
        guard choices[shown.id] ?? isSensitive else { return nil }
        return isSensitive ? .sensitive : .hidden
    }

    public mutating func reveal(_ status: Status) {
        choices[status.displayed.id] = false
    }

    public mutating func hide(_ status: Status) {
        choices[status.displayed.id] = true
    }
}
