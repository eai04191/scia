public import Foundation
import os

/// カードが付く前に受け取った投稿を、いつ取り直すかの予定。
///
/// Mastodonは投稿を配信してからリンク先を取りに行ってカードを付け、付けたことをストリーミングで知らせない。
/// 自分のサーバーの投稿には数秒で付き、ほかのサーバーの投稿は、受け取ってから0〜60秒のランダムな時間をおいて取りに行く。
/// 取りに行く仕事は優先度の低いキューに入るため、混んでいるサーバーではさらに遅れる。
/// そのため、リンク先だけのカードを出している投稿を、初めて見てから`firstDelay`後から`giveUpAfter`まで取り直す。
/// 取り直しは投稿ごとに送らず、`interval`に1回、そのとき待っている投稿をまとめて送る。
/// リンクの投稿がいくつ流れてきても、リクエストは`interval`に1回を超えず、トークンごとのレート制限（Mastodonの既定で5分に300回）の1割に収まる。
/// 画面に出ていない投稿は取り直さず、また見えたときに、`giveUpAfter`を過ぎていても1回だけ取り直す。
/// Mastodonは編集でカードを消して取りに行き直すため、予定は投稿の版（IDと編集した日時の組）ごとに立てる。
public struct LinkCardRefreshSchedule: Sendable {
    /// 投稿の版。
    public struct Version: Hashable, Sendable {
        public let statusID: Status.ID
        public let editedAt: Date?

        public init(_ status: Status) {
            self.init(statusID: status.id, editedAt: status.editedAt)
        }

        init(statusID: Status.ID, editedAt: Date?) {
            self.statusID = statusID
            self.editedAt = editedAt
        }
    }

    /// 取り直す1件。
    public struct Attempt: Sendable, Equatable {
        public let version: Version
        /// 初めて見た時刻。
        public let firstSeen: Date
        /// この取り直しを含めて、何回取り直したか。
        public let count: Int
        /// これで最後で、カードが届かなければ諦める。
        public let isFinal: Bool
    }

    /// 初めて見てから、何秒後に最初に取り直すか。自分のサーバーの投稿には、このころにはカードが付いている。
    public static let firstDelay: TimeInterval = 3
    /// 取り直しのリクエストの間隔。カードが付いてから表示されるまでの遅れは、長くてもこの間隔になる。
    public static let interval: TimeInterval = 10
    /// 初めて見てから、何秒経ったら諦めるか。ほかのサーバーの投稿の、最大1分の遅れと、キューの待ちと、取得の時間を待つ。
    public static let giveUpAfter: TimeInterval = 180
    /// 作られてから（編集した投稿は編集してから）これより経った投稿は、サーバーがカードを付け終えたとみなし、取り直さない。
    /// 初めて見てからこれより経った投稿も、見えないまま予定が過ぎたものとして忘れる。
    public static let maximumAge: TimeInterval = 600

    private struct Entry: Sendable {
        let firstSeen: Date
        /// 取り直した回数。
        var attempts = 0
        /// 最後に取り直した時刻。まとめて送れる件数を超えたとき、長く取り直していない投稿から送るために使う。
        var lastAttempt: Date?

        var firstDate: Date {
            firstSeen.addingTimeInterval(LinkCardRefreshSchedule.firstDelay)
        }
    }

    private var entries: [Version: Entry] = [:]
    /// 取り直し終えた版。カードが届いたか、諦めたか、サーバーにもうない。
    private var finished: Set<Version> = []
    /// 最後に取り直しを送った時刻。
    private var lastRequest: Date?

    public init() {}

    /// リンク先だけのカードを出している投稿を見た。初めて見た投稿の予定を立てる。ブーストなら、ブーストされた投稿を渡す。
    public mutating func note(_ statuses: [Status], now: Date) {
        for status in statuses {
            let version = Version(status)
            guard entries[version] == nil, !finished.contains(version), case .link = LinkCard(status: status),
                  now.timeIntervalSince(status.editedAt ?? status.createdAt) <= Self.maximumAge
            else { continue }
            entries[version] = Entry(firstSeen: now)
        }
    }

    /// `now`の時点で取り直す投稿。前の取り直しから`interval`経っていれば、見えていて最初の取り直しの時刻を過ぎた投稿を、
    /// 長く取り直していない順に`limit`件まで返し、取り直したことにする。諦める投稿は、取り直し終えたことにする。
    public mutating func due(now: Date, visible: Set<Version>, limit: Int) -> [Attempt] {
        forgetExpired(now: now)
        if let lastRequest, now < lastRequest.addingTimeInterval(Self.interval) { return [] }
        let due = entries
            .filter { visible.contains($0.key) && $0.value.firstDate <= now }
            .sorted { lhs, rhs in
                let left = (lhs.value.lastAttempt ?? .distantPast, lhs.value.firstSeen, lhs.key.statusID)
                let right = (rhs.value.lastAttempt ?? .distantPast, rhs.value.firstSeen, rhs.key.statusID)
                return left < right
            }
            .prefix(limit)
        guard !due.isEmpty else { return [] }
        lastRequest = now
        return due.map { version, entry in
            var entry = entry
            entry.attempts += 1
            entry.lastAttempt = now
            let isFinal = now >= entry.firstSeen.addingTimeInterval(Self.giveUpAfter)
            if isFinal {
                entries[version] = nil
                finished.insert(version)
            } else {
                entries[version] = entry
            }
            return Attempt(version: version, firstSeen: entry.firstSeen, count: entry.attempts, isFinal: isFinal)
        }
    }

    /// 見えている投稿のうち、次に取り直す時刻。なければnil。
    public func nextDate(visible: Set<Version>) -> Date? {
        guard let first = entries.filter({ visible.contains($0.key) }).map(\.value.firstDate).min() else { return nil }
        guard let lastRequest else { return first }
        return max(first, lastRequest.addingTimeInterval(Self.interval))
    }

    /// 取り直す必要がなくなった。カードが届いたか、サーバーにもうない。
    public mutating func finish(_ versions: some Sequence<Version>) {
        for version in versions {
            entries[version] = nil
            finished.insert(version)
        }
    }

    private mutating func forgetExpired(now: Date) {
        let expired = entries.filter { now.timeIntervalSince($0.value.firstSeen) > Self.maximumAge }.map(\.key)
        finish(expired)
    }
}

/// カードが付く前に受け取った投稿を、見えている間だけ、予定どおりにまとめて取り直し、届いたカードを表示へ反映する。
/// セッションの中で1つ持ち、ホーム、通知、プロフィールの一覧が、見えている投稿を知らせる。
@MainActor
public final class LinkCardRefresher {
    public typealias Fetch = @Sendable ([Status.ID]) async throws -> [Status]
    /// カードの付いた、取り直した投稿を渡す。表示しているすべての一覧で、その投稿とそれをブーストした投稿にカードを付ける。
    public typealias Apply = @MainActor (Status) -> Void

    private let fetch: Fetch
    private let apply: Apply
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var schedule = LinkCardRefreshSchedule()
    /// 一覧ごとの、見えていて、リンク先だけのカードを出している投稿。
    private var visible: [ObjectIdentifier: [Status]] = [:]
    private var loop: Task<Void, Never>?
    /// 取り直しの結果を待っている。待っている間に見える投稿が変わっても、結果を捨てないよう、ループを作り直さない。
    private var isFetching = false
    /// サーバーが複数の投稿をまとめて読めない。このセッションでは取り直さない。
    private var isUnsupported = false
    private let logger = SciaLog.logger(category: "timeline")

    public init(
        fetch: @escaping Fetch,
        apply: @escaping Apply,
        now: @escaping @MainActor () -> Date = SystemTime.now,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await SystemTime.clock.sleep(for: $0) }
    ) {
        self.fetch = fetch
        self.apply = apply
        self.now = now
        self.sleep = sleep
    }

    public convenience init(client: MastodonClient, apply: @escaping Apply) {
        self.init(fetch: { try await client.statuses($0) }, apply: apply)
    }

    /// `source`の一覧で見えていて、リンク先だけのカードを出している投稿を知らせる。画面から消えたら空で知らせる。
    public func setVisible(_ statuses: [Status], from source: AnyObject) {
        guard !isUnsupported else { return }
        visible[ObjectIdentifier(source)] = statuses
        schedule.note(statuses, now: now())
        guard !isFetching else { return }
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    /// 取り直しの予定がなくなるまで待つ。テストで使う。
    func waitUntilIdle() async {
        while let loop {
            await loop.value
            if loop == self.loop { return }
        }
    }

    private var visibleVersions: Set<LinkCardRefreshSchedule.Version> {
        Set(visible.values.joined().map(LinkCardRefreshSchedule.Version.init))
    }

    private func run() async {
        while !Task.isCancelled, !isUnsupported {
            let versions = visibleVersions
            let due = schedule.due(now: now(), visible: versions, limit: MastodonClient.multipleStatusesLimit)
            if !due.isEmpty {
                await refresh(due)
                continue
            }
            guard let next = schedule.nextDate(visible: versions) else { return }
            let wait = max(next.timeIntervalSince(now()), 0)
            guard (try? await sleep(.seconds(wait))) != nil else { return }
        }
    }

    private func refresh(_ attempts: [LinkCardRefreshSchedule.Attempt]) async {
        let ids = attempts.map(\.version.statusID)
        isFetching = true
        defer { isFetching = false }
        do {
            // スクロールなど使う人の操作から始めたTaskでも、取り直しはアプリが自分で送るものなので、レート制限で止めている間は控える。
            let fetch = fetch
            let statuses = try await RequestOrigin.$current.withValue(.automatic) {
                try await fetch(ids)
            }
            let carded = statuses.filter { $0.card != nil }
            for status in carded {
                apply(status)
            }
            // カードが届いた版と、返らなかった投稿（消えたか見られなくなった）は、もう取り直さない。
            let cardedIDs = Set(carded.map(\.id))
            let finishedIDs = cardedIDs.union(Set(ids).subtracting(statuses.map(\.id)))
            schedule.finish(attempts.map(\.version).filter { finishedIDs.contains($0.statusID) })
            logger.info("link card refresh requested=\(ids.count, privacy: .public) carded=\(carded.count, privacy: .public)")
            logOutcomes(of: attempts, cardedIDs: cardedIDs)
        } catch is FeatureUnavailable {
            isUnsupported = true
        } catch {
            logger.error("link card refresh failed: \(error.localizedDescription, privacy: .public)")
            logOutcomes(of: attempts, cardedIDs: [])
        }
    }

    /// 間隔や諦めるまでの時間を見直せるよう、カードが届くまでの時間と、諦めた投稿を残す。
    private func logOutcomes(of attempts: [LinkCardRefreshSchedule.Attempt], cardedIDs: Set<Status.ID>) {
        let now = now()
        for attempt in attempts {
            let elapsed = Int(now.timeIntervalSince(attempt.firstSeen).rounded())
            if cardedIDs.contains(attempt.version.statusID) {
                logger.info("link card arrived elapsed=\(elapsed, privacy: .public)s attempts=\(attempt.count, privacy: .public)")
            } else if attempt.isFinal {
                logger.info("link card gave up elapsed=\(elapsed, privacy: .public)s attempts=\(attempt.count, privacy: .public)")
            }
        }
    }
}
