#if DEBUG
import Foundation
import SciaCore

/// ダミー投稿の投票。サーバーにないため、投票と読み直しは通信せず、少し待ってからここで結果を作って返す。
/// 投票の送り終えるまでの表示と、結果の棒が伸びる動きを、サーバーの投票を使わずに何度でも確かめるため。
enum DummyPolls {
    /// ダミーの投票のIDに付ける目印。目印のある投票だけ、通信せずに答える。
    static let idPrefix = "dummy-poll-"
    /// 送ってから結果を返すまで。送っている途中の表示を見られるよう、少し待つ。
    static let delay: Duration = .seconds(1)

    /// 流したダミーの投票の、今の状態。
    @MainActor private static var polls: [Poll.ID: Poll] = [:]

    @MainActor static func register(_ poll: Poll) {
        polls[poll.id] = poll
    }

    static func isDummy(_ pollID: Poll.ID) -> Bool {
        pollID.hasPrefix(idPrefix)
    }

    /// 選んだ選択肢に1票ずつ足し、投票した人を1人足した結果を返す。
    static func vote(_ pollID: Poll.ID, choices: [Int]) async throws -> Poll {
        try await Task.sleep(for: delay)
        return try await MainActor.run {
            guard let poll = polls[pollID] else { throw URLError(.fileDoesNotExist) }
            let options = poll.options.enumerated().map { index, option in
                Poll.Option(title: option.title, votesCount: option.votesCount.map { choices.contains(index) ? $0 + 1 : $0 })
            }
            let voted = Poll(
                id: poll.id,
                expiresAt: poll.expiresAt,
                expired: poll.expired,
                multiple: poll.multiple,
                votesCount: poll.votesCount + choices.count,
                votersCount: poll.votersCount.map { $0 + 1 },
                options: options,
                emojis: poll.emojis,
                voted: true,
                ownVotes: choices
            )
            polls[pollID] = voted
            return voted
        }
    }

    static func poll(_ pollID: Poll.ID) async throws -> Poll {
        try await Task.sleep(for: delay)
        return try await MainActor.run {
            guard let poll = polls[pollID] else { throw URLError(.fileDoesNotExist) }
            return poll
        }
    }
}
#endif
