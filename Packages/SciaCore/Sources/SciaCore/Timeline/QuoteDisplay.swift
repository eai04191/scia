/// 投稿の中の引用をどう出すか。決まりは`docs/quote.md`。
public enum QuoteDisplay: Equatable, Sendable {
    /// 引用元を囲みで出す。
    case post(Status)
    /// 引用元を出さず、出せない理由の1行を出す。
    case unavailable(Reason)
    /// ブロックかミュートしている人の投稿。押して開くまで中身を出さず、理由の1行を出す。
    case concealed(Reason, Status)
    /// 引用元がフィルターの「隠す」に一致した。外側の投稿は出したまま、隠したことを示す1行を出す。
    case filtered

    /// 引用元を出さない理由。
    public enum Reason: Equatable, Sendable {
        case pending
        /// 引用された人が断ったか、取り消した。
        case withdrawn
        case deleted
        case unauthorized
        case blockedAccount
        case blockedDomain
        case mutedAccount

        init(_ state: Quote.State) {
            self = switch state {
            case .pending: .pending
            case .rejected, .revoked: .withdrawn
            case .deleted: .deleted
            // 出せる`state`なのに引用元の投稿が読めなかったときは、見られないものとして扱う。
            case .accepted, .unauthorized: .unauthorized
            case .blockedAccount: .blockedAccount
            case .blockedDomain: .blockedDomain
            case .mutedAccount: .mutedAccount
            }
        }
    }

    /// `status`の引用の出し方。引用がなければnil。ブーストなら、ブーストされた投稿を渡す。
    /// - Parameters:
    ///   - isRevealed: ブロックかミュートしている人の引用元を、押して開いた。
    ///   - verdict: 引用元の投稿にフィルターをどう当てるか。外側の投稿と同じ一覧の場所で決める。
    public init?(quoting status: Status, isRevealed: Bool, verdict: (Status) -> FilterVerdict) {
        guard let quote = status.quote else { return nil }
        let reason = Reason(quote.state)
        guard let quoted = quote.quotedStatus else {
            self = .unavailable(reason)
            return
        }
        switch quote.state {
        case .accepted:
            break
        case .blockedAccount, .blockedDomain, .mutedAccount:
            guard isRevealed else {
                self = .concealed(reason, quoted)
                return
            }
        case .pending, .rejected, .revoked, .deleted, .unauthorized:
            // 投稿を削除した応答などでは、出せない`state`でも引用元が入る。`state`に従って出さない。
            self = .unavailable(reason)
            return
        }
        self = verdict(quoted).isHidden ? .filtered : .post(quoted)
    }
}

/// 囲みの中の、引用元がさらに引用している投稿。囲みは1段だけにし、引用していることを示す1行だけを出す。
public enum NestedQuote: Equatable, Sendable {
    /// 押すと、この投稿のスレッドを開く。
    case link(Status.ID)
    /// IDが届かないため押せず、出せない理由を出す。
    case unavailable(QuoteDisplay.Reason)

    /// 引用元の投稿の`quote`（`ShallowQuote`）から決める。引用していなければnil。
    /// IDが入るのは、`accepted`とブロック・ミュートの3つの`state`だけ。
    public init?(_ quote: Quote?) {
        guard let quote else { return nil }
        switch quote.state {
        case .accepted, .blockedAccount, .blockedDomain, .mutedAccount:
            if let id = quote.quotedStatusID {
                self = .link(id)
            } else {
                self = .unavailable(.unauthorized)
            }
        case .pending, .rejected, .revoked, .deleted, .unauthorized:
            self = .unavailable(QuoteDisplay.Reason(quote.state))
        }
    }
}

/// 一覧で、ブロックかミュートしている人の引用元のうち、押して開いたもの。
/// 引用した投稿のIDで覚え、同じ投稿のブーストや通知の行もそろえる。覚えるのはアプリを起動している間だけ。
public struct QuoteReveals: Sendable, Equatable {
    private var revealed: Set<Status.ID> = []

    public init() {}

    /// ブーストなら、ブーストされた投稿で決める。
    public func isRevealed(_ status: Status) -> Bool {
        revealed.contains(status.displayed.id)
    }

    public mutating func reveal(_ status: Status) {
        revealed.insert(status.displayed.id)
    }
}

/// 引用元の、受け取ったあとの変化。編集と削除の知らせ、読み込んだあとのミュートとブロックを、どの一覧の囲みにも当てるためにセッションで1つ持つ。
/// 一覧が持つ投稿の中の引用元は書き換えず、囲みを出すときに当てる。ミュートやブロックを解除したときに、元の引用元に戻せるようにするため。
/// 覚えるのはアプリを起動している間だけ。
public struct QuoteSourceChanges: Sendable, Equatable {
    /// 編集の知らせで届いた投稿。どの投稿が引用されているかは知らせからは分からないため、届いた編集をすべて覚える。編集の知らせは少ないので、捨てない。
    private var edited: [Status.ID: Status] = [:]
    private var deletedIDs: Set<Status.ID> = []
    /// 読み込んだあとにミュートかブロックしたアカウントと、その引用元を隠す`state`。nilは、どちらも解除したこと。
    /// 解除も覚えるのは、ミュートやブロックをしている間に読んだ引用は、サーバーが`state`を`muted_account`などにして返すため。
    private var accountStates: [String: Quote.State?] = [:]

    public init() {}

    /// 投稿の編集が届いた。
    public mutating func edit(_ status: Status) {
        edited[status.id] = status
    }

    /// 投稿が削除された。
    public mutating func delete(_ id: Status.ID) {
        deletedIDs.insert(id)
        edited[id] = nil
    }

    /// アカウントをミュートかブロックした（`state`は`.mutedAccount`か`.blockedAccount`）か、どちらでもなくなった（nil）。
    public mutating func setAccount(_ id: String, concealedAs state: Quote.State?) {
        accountStates[id] = .some(state)
    }

    /// 変化を当てた、表示する投稿。ブーストなら、ブーストされた投稿を渡す。引用がなければそのまま返す。
    public func applying(to status: Status) -> Status {
        guard let quote = status.quote else { return status }
        return status.replacingQuote(applying(to: quote))
    }

    private func applying(to quote: Quote) -> Quote {
        guard let id = quote.quotedStatusID ?? quote.quotedStatus?.id else { return quote }
        if deletedIDs.contains(id) {
            return Quote(state: "deleted")
        }
        guard let quoted = quote.quotedStatus else { return quote }
        // 届いた編集より新しい版を読み直していれば、読み直した版を使う。切れている間の編集を取りこぼした知らせで、新しい版を戻さないため。
        var source = edited[id].flatMap { Self.isNewer($0, than: quoted) ? $0 : nil } ?? quoted
        // 引用元の中の引用はIDだけで届くため、削除だけを当てる。
        if let nested = source.quote, let nestedID = nested.quotedStatusID, deletedIDs.contains(nestedID) {
            source = source.replacingQuote(Quote(state: "deleted"))
        }
        switch (quote.state, accountStates[source.account.id]) {
        case (.accepted, .some(.some(let state))), (.mutedAccount, .some(.some(let state))), (.blockedAccount, .some(.some(let state))):
            return Quote(state: state.rawValue, quotedStatus: source)
        case (.mutedAccount, .some(nil)), (.blockedAccount, .some(nil)):
            return Quote(state: Quote.State.accepted.rawValue, quotedStatus: source)
        default:
            return Quote(state: quote.rawState, quotedStatus: source)
        }
    }

    /// `edited`が`other`より新しい版か。編集されていない版は、どの編集よりも古い。
    private static func isNewer(_ edited: Status, than other: Status) -> Bool {
        guard let editedAt = edited.editedAt else { return false }
        guard let otherEditedAt = other.editedAt else { return true }
        return editedAt > otherEditedAt
    }
}
