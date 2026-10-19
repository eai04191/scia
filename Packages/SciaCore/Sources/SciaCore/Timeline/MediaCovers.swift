/// 一覧で添付ファイルを覆う理由。覆いに出す文言を分ける。
public enum MediaCover: Sendable, Equatable {
    /// 投稿者が閲覧注意か注意書きを付けた。
    case sensitive
    /// 閲覧注意のない投稿を、使う人が隠した。
    case hidden
    /// 添付ファイルをぼかすフィルターに一致した。一致したフィルターの名前を持つ。
    case filtered([String])
}

/// 一覧で投稿の添付ファイルを覆うか。
///
/// 閲覧注意と注意書きのある投稿と、添付ファイルをぼかすフィルターに一致した投稿は最初から覆う。
/// 使う人が開いたり隠したりした投稿は、閲覧注意かどうかにかかわらずその選択に従う。
/// 選択は元の投稿のIDで覚え、同じ投稿のブーストや通知の行もそろえる。覚えるのはアプリを起動している間だけ。
public struct MediaCovers: Sendable, Equatable {
    /// 投稿ごとに、覆うと選んだか。
    private var choices: [Status.ID: Bool] = [:]
    /// 覆いを外した投稿。リンクカードの画像は、外したら覆い直さないため、隠した選択とは分けて覚える。
    private var revealed: Set<Status.ID> = []

    public init() {}

    /// 覆っていればその理由、覆っていなければnil。ブーストなら元の投稿で決める。
    /// 開いたあとに隠した投稿は、開く前と同じ理由にする。フィルターに一致し、閲覧注意も付いていれば、フィルターの名前を出す。
    /// 閲覧注意は投稿者が付けるもので、使う人が自分で決めたフィルターのほうが、なぜ覆ったかを示せるため。
    /// - Parameter filterTitles: 添付ファイルをぼかすフィルターのうち、一致したものの名前。
    public func cover(for status: Status, filterTitles: [String]) -> MediaCover? {
        let shown = status.displayed
        return cover(forStatusID: shown.id, isSensitive: shown.sensitive || !shown.spoilerText.isEmpty, filterTitles: filterTitles)
    }

    /// 閲覧注意かどうかを投稿の外から渡して決める。編集履歴で、手元の投稿より新しい版の閲覧注意で覆うために使う。
    /// - Parameters:
    ///   - statusID: 元の投稿のID。使う人が開いた・隠した選択を、このIDで引く。
    ///   - isSensitive: 閲覧注意か注意書きがある。
    public func cover(forStatusID statusID: Status.ID, isSensitive: Bool, filterTitles: [String]) -> MediaCover? {
        guard choices[statusID] ?? (isSensitive || !filterTitles.isEmpty) else { return nil }
        if !filterTitles.isEmpty { return .filtered(filterTitles) }
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

    /// 使う人が隠した。開いた投稿と、まだ選んでいない投稿ではfalse。
    /// - Parameter statusID: 元の投稿のID。
    public func isHidden(statusID: Status.ID) -> Bool {
        choices[statusID] == true
    }

    public mutating func reveal(_ status: Status) {
        choices[status.displayed.id] = false
        revealed.insert(status.displayed.id)
    }

    public mutating func hide(_ status: Status) {
        choices[status.displayed.id] = true
    }
}
