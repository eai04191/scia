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
    /// 覆いを外した投稿。リンクカードの画像は、外したら覆い直さないため、隠した選択とは分けて覚える。
    private var revealed: Set<Status.ID> = []

    public init() {}

    /// 覆っていればその理由、覆っていなければnil。ブーストなら元の投稿で決める。
    /// 開いたあとに隠した閲覧注意の投稿は、開く前と同じく`.sensitive`にする。
    public func cover(for status: Status) -> MediaCover? {
        let shown = status.displayed
        let isSensitive = shown.sensitive || !shown.spoilerText.isEmpty
        guard choices[shown.id] ?? isSensitive else { return nil }
        return isSensitive ? .sensitive : .hidden
    }

    /// リンクカードの画像を覆っていれば`.sensitive`、覆っていなければnil。画像のないカードとカードのない投稿ではnil。
    /// 閲覧注意と注意書きのある投稿を、添付ファイルと同じく、覆いを外すまで覆う。添付ファイルを隠した選択には従わない。
    /// カードの付いた投稿に、本文を変えずに添付ファイルを足して編集すると、Mastodonはカードを残すため、添付ファイルとカードの画像が同じ投稿に並ぶことがある。
    public func linkCardImageCover(for status: Status) -> MediaCover? {
        let shown = status.displayed
        guard shown.card?.image != nil, shown.sensitive || !shown.spoilerText.isEmpty, !revealed.contains(shown.id) else { return nil }
        return .sensitive
    }

    public mutating func reveal(_ status: Status) {
        choices[status.displayed.id] = false
        revealed.insert(status.displayed.id)
    }

    public mutating func hide(_ status: Status) {
        choices[status.displayed.id] = true
    }
}
