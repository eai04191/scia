public import Foundation

/// 投稿の投票を、一覧の行でどう見せるか。決まりは`docs/poll.md`にある。
///
/// まだ投票していない、締め切る前の投票は、選択肢を選んで投票する形にする。投票した後、締め切った後、結果を見ると選んだときは、結果の形にする。
/// 自分の投票には投票できず、サーバーは自分の投票を投票済みとして返すため、結果の形になる。
public struct PollDisplay: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// 選択肢を選んで投票する。
        case voting
        /// 結果を出す。
        case results
    }

    public struct Option: Equatable, Sendable {
        public let title: String
        /// 選んでいる。投票する形でだけ使う。
        public let isSelected: Bool
        /// 自分が票を入れた。
        public let isOwnVote: Bool
        /// 全体のうちのこの選択肢の割合（0〜1）。締め切るまで票数を隠す投票ではnil。
        public let fraction: Double?
        /// 最も票の多い選択肢。並んだときはどれも。票数を隠しているか、まだ票がなければfalse。
        public let isLeading: Bool
    }

    public let mode: Mode
    /// 複数の選択肢を選べる。
    public let multiple: Bool
    public let options: [Option]
    /// 投票のボタンを押せる。1つ以上選んでいて、送っている途中でない。
    public let canSubmit: Bool
    /// 投票を送っている途中。
    public let isSubmitting: Bool
    /// 投票する形から、投票せずに結果を見られる。締め切るまで票数を隠す投票では、見ても割合が出ないため見せない。
    public let canRevealResults: Bool
    /// 結果の形から、投票する形に戻れる。結果を見ると選んだだけで、まだ投票していない。
    public let canReturnToVoting: Bool
    /// 結果を読み直せる。サーバーが締め切ったと返した投票は結果が変わらないため、読み直さない。
    /// 締め切りの日時を過ぎただけで、サーバーからはまだ締め切る前の結果しか読んでいない投票は、最終結果を読めるよう残す。
    public let canRefresh: Bool
    /// 結果を読み直している途中。
    public let isRefreshing: Bool
    /// 選択肢の下に出す、人数か票数と、締め切り。
    public let summary: String

    /// - Parameter allowsVoting: 投票する形にしてよい。投票の終了の通知のように、結果を知るために出す場所ではfalseにする。
    /// - Parameter locale: 人数と票数の区切り方を決める、端末の地域。
    public init(poll: Poll, choices: PollChoices, now: Date, allowsVoting: Bool = true, locale: Locale = .autoupdatingCurrent) {
        let isExpired = poll.isExpired(at: now)
        let showsResults = !allowsVoting || poll.voted || isExpired || choices.isRevealed(poll.id)
        mode = showsResults ? .results : .voting
        multiple = poll.multiple
        isSubmitting = choices.isSubmitting(poll.id)
        isRefreshing = choices.isRefreshing(poll.id)
        let selection = showsResults ? [] : choices.selection(of: poll)
        // 複数選べる投票では、1人が複数の票を入れるため、票の数ではなく投票した人の数に対する割合にする。
        let total = poll.votersCount ?? poll.votesCount
        let counts = poll.options.compactMap(\.votesCount)
        let hidesTotals = counts.count < poll.options.count
        let most = counts.max() ?? 0
        options = poll.options.enumerated().map { index, option in
            Option(
                title: option.title,
                isSelected: selection.contains(index),
                isOwnVote: poll.ownVotes.contains(index),
                fraction: option.votesCount.map { total > 0 ? Double($0) / Double(total) : 0 },
                isLeading: !hidesTotals && most > 0 && option.votesCount == most
            )
        }
        canSubmit = !showsResults && !selection.isEmpty && !isSubmitting
        canRevealResults = !showsResults && !hidesTotals
        canReturnToVoting = allowsVoting && showsResults && !poll.voted && !isExpired
        canRefresh = allowsVoting && showsResults && !poll.expired
        var parts = [poll.votersCount.map { "\(Self.countText($0, locale: locale))人" } ?? "\(Self.countText(poll.votesCount, locale: locale))票"]
        if let expiresAt = poll.expiresAt {
            parts.append(isExpired ? "終了" : Self.remainingText(until: expiresAt, now: now))
        }
        if hidesTotals, !isExpired {
            parts.append("結果は締め切り後")
        }
        summary = parts.joined(separator: "・")
    }

    /// 人数と票数。桁が多くても読めるよう、端末の地域の区切り方で区切る。
    static func countText(_ count: Int, locale: Locale) -> String {
        count.formatted(.number.locale(locale))
    }

    /// 締め切りまでの残り。投稿の相対時刻の表記と同じ区切りで、切り捨てて数える。
    static func remainingText(until date: Date, now: Date) -> String {
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        return switch seconds {
        case ..<60: "残り\(seconds)秒"
        case ..<3_600: "残り\(seconds / 60)分"
        case ..<86_400: "残り\(seconds / 3_600)時間"
        default: "残り\(seconds / 86_400)日"
        }
    }
}

extension Poll {
    /// `now`の時点で締め切っている。サーバーの`expired`は返した時点のものなので、締め切りの日時も見る。
    public func isExpired(at now: Date) -> Bool {
        expired || expiresAt.map { $0 <= now } == true
    }

    /// 選択肢の並びと、複数選べるかが同じ。Mastodonは、編集で選択肢を変えても投票のIDを変えず、票だけを消すため、同じ投票かはこれも見て決める。
    public func hasSameChoices(as other: Poll) -> Bool {
        multiple == other.multiple && options.map(\.title) == other.options.map(\.title)
    }
}

/// 投票する前に選んでいる選択肢と、結果を見ると選んだ投票、送っている途中の投票。一覧ごとに、アプリを起動している間だけ覚える。
///
/// 投票はIDで覚え、同じ投稿のブーストや通知の行もそろえる。選んでいる選択肢は、選んだときの選択肢の並びも覚え、
/// 編集で選択肢が変わったら忘れる。選択肢は位置で覚えるため、残すと選んでいない選択肢に投票してしまう。
public struct PollChoices: Equatable, Sendable {
    private struct Selection: Equatable, Sendable {
        let titles: [String]
        let multiple: Bool
        var indices: Set<Int>

        func matches(_ poll: Poll) -> Bool {
            multiple == poll.multiple && titles == poll.options.map(\.title)
        }
    }

    private var selections: [Poll.ID: Selection] = [:]
    private var revealed: Set<Poll.ID> = []
    private var submitting: Set<Poll.ID> = []
    private var refreshing: Set<Poll.ID> = []

    public init() {}

    /// 選んでいる選択肢。選んだあとに編集で選択肢が変わっていたら、空にする。
    public func selection(of poll: Poll) -> Set<Int> {
        guard let selection = selections[poll.id], selection.matches(poll) else { return [] }
        return selection.indices
    }

    /// 選択肢を選ぶ。複数選べる投票では選んでいれば外し、複数選べない投票では選んでいたものと入れ替える。
    /// 送っている途中は、送った選択肢と食い違わないよう、変えない。
    public mutating func toggle(_ index: Int, in poll: Poll) {
        guard poll.options.indices.contains(index), !submitting.contains(poll.id) else { return }
        var selection = selection(of: poll)
        if poll.multiple {
            if selection.remove(index) == nil {
                selection.insert(index)
            }
        } else {
            selection = [index]
        }
        selections[poll.id] = Selection(titles: poll.options.map(\.title), multiple: poll.multiple, indices: selection)
    }

    public func isRevealed(_ pollID: Poll.ID) -> Bool {
        revealed.contains(pollID)
    }

    /// 投票せずに結果を見る。選んでいた選択肢は、投票する形に戻ったときのために残す。
    public mutating func reveal(_ pollID: Poll.ID) {
        revealed.insert(pollID)
    }

    public mutating func returnToVoting(_ pollID: Poll.ID) {
        revealed.remove(pollID)
    }

    public func isSubmitting(_ pollID: Poll.ID) -> Bool {
        submitting.contains(pollID)
    }

    public mutating func beginSubmitting(_ pollID: Poll.ID) {
        submitting.insert(pollID)
    }

    /// 送り終えた。投票できたら、選んでいた選択肢はもう使わないため忘れる。失敗したら、選び直さずに押し直せるよう残す。
    public mutating func endSubmitting(_ pollID: Poll.ID, succeeded: Bool) {
        submitting.remove(pollID)
        if succeeded {
            selections[pollID] = nil
            revealed.remove(pollID)
        }
    }

    public func isRefreshing(_ pollID: Poll.ID) -> Bool {
        refreshing.contains(pollID)
    }

    public mutating func beginRefreshing(_ pollID: Poll.ID) {
        refreshing.insert(pollID)
    }

    public mutating func endRefreshing(_ pollID: Poll.ID) {
        refreshing.remove(pollID)
    }
}
