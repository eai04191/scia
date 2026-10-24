public import Foundation

/// 投稿に一致したサーバーのフィルターを、一覧の場所で絞り、どう出すかを決める。
/// https://docs.joinmastodon.org/api/guidelines/#server-filtered
///
/// 自分の投稿には当てない。ドキュメントにはないが、公式のWebクライアントに合わせる。サーバーは自分の投稿にも一致したフィルターを付けるが、
/// 投稿した直後の自分の投稿が一覧から消えると、投稿に失敗したように見えるため。
/// 代わりに、一致したフィルターの名前を返し、注記だけを出す。昔作ったフィルターに一致する話題を自分が書くと、それに触れた人の投稿が黙って隠れるため、
/// フィルターがあることに気づけるようにする。
public struct StatusFiltering: Sendable, Equatable {
    /// この一覧の場所。フィルターは、使う場所にこれを含むものだけを当てる。
    public let context: FilterResult.Context
    /// 自分のアカウントのID。
    public let myAccountID: String?
    /// 「隠す」のフィルターに一致した投稿を隠すか。falseなら隠さずに警告で折りたたむ。
    /// ブックマークやお気に入りのように、自分で残した投稿を並べる一覧で使う。公式のWebクライアントと同じ（`warnInsteadOfHide`）。
    public let hidesMatches: Bool

    public init(context: FilterResult.Context, myAccountID: String?, hidesMatches: Bool = true) {
        self.context = context
        self.myAccountID = myAccountID
        self.hidesMatches = hidesMatches
    }

    /// `now`の時点で、`status`をどう出すか。ブーストなら元の投稿で決める。
    public func verdict(for status: Status, now: Date = SystemTime.now()) -> FilterVerdict {
        let shown = status.displayed
        // サーバーはブーストにも元の投稿にも同じ結果を付ける。公式のWebクライアントと同じく、元の投稿の結果を先に見る。
        let results = shown.filtered.isEmpty ? status.filtered : shown.filtered
        let filters = results.map(\.filter).filter { filter in
            filter.context.contains(context) && filter.expiresAt.map { $0 > now } ?? true
        }
        if shown.account.id == myAccountID {
            return FilterVerdict(isHidden: false, warningTitles: [], mediaTitles: [], ownMatchTitles: Self.titles(of: filters))
        }
        if hidesMatches, filters.contains(where: { $0.filterAction == .hide }) {
            return FilterVerdict(isHidden: true, warningTitles: [], mediaTitles: [], ownMatchTitles: [])
        }
        return FilterVerdict(
            isHidden: false,
            // 知らない扱いは、ドキュメントに従って警告にする。
            warningTitles: Self.titles(of: filters.filter { $0.filterAction != .blur }),
            mediaTitles: Self.titles(of: filters.filter { $0.filterAction == .blur }),
            ownMatchTitles: []
        )
    }

    /// 同じ名前は1つにする。
    private static func titles(of filters: [FilterResult.Filter]) -> [String] {
        var seen: Set<String> = []
        return filters.map(\.title).filter { seen.insert($0).inserted }
    }
}

/// 投稿をフィルターでどう出すか。
public struct FilterVerdict: Sendable, Equatable {
    /// 一覧に出さない。
    public let isHidden: Bool
    /// 警告で投稿を折りたたむフィルターの名前。折りたたまなければ空。
    public let warningTitles: [String]
    /// 添付ファイルをぼかすフィルターの名前。ぼかさなければ空。
    public let mediaTitles: [String]
    /// 自分の投稿が一致したフィルターの名前。扱いによらず並べる。自分の投稿でないか、一致しなければ空。
    public let ownMatchTitles: [String]

    public static let none = FilterVerdict(isHidden: false, warningTitles: [], mediaTitles: [], ownMatchTitles: [])
}

/// 一覧で、フィルターの警告で折りたたんだ投稿のうち、開いたもの。
///
/// 開いたら閉じ直さない。公式のWebクライアントと同じく、警告は本文を読むかを一度だけ尋ねるもので、
/// 注意書き（CW）のように読み返すたびに開閉するものではないため。
/// 開いたかは元の投稿のIDで覚え、同じ投稿のブーストの行もそろえる。覚えるのはアプリを起動している間だけ。
public struct FilterWarnings: Sendable, Equatable {
    /// この一覧で当てるフィルター。nilなら当てない。
    public var filtering: StatusFiltering?
    private var revealed: Set<Status.ID> = []

    public init(filtering: StatusFiltering? = nil) {
        self.filtering = filtering
    }

    /// `status`をどう出すか。警告で折りたたんだ投稿を開いていれば、警告の名前を空にして返す。
    public func verdict(for status: Status, now: Date = SystemTime.now()) -> FilterVerdict {
        guard let filtering else { return .none }
        let verdict = filtering.verdict(for: status, now: now)
        guard !verdict.warningTitles.isEmpty, revealed.contains(status.displayed.id) else { return verdict }
        return FilterVerdict(isHidden: verdict.isHidden, warningTitles: [], mediaTitles: verdict.mediaTitles, ownMatchTitles: verdict.ownMatchTitles)
    }

    public mutating func reveal(_ status: Status) {
        revealed.insert(status.displayed.id)
    }
}
