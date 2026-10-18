public import Foundation
import os

/// カードが付く前に受け取った投稿を、いつ取り直すかの予定。
///
/// Mastodonは投稿を配信してからリンク先を取りに行ってカードを付け、付けたことをストリーミングで知らせない。
/// 自分のサーバーの投稿には数秒で付き、ほかのサーバーの投稿は、受け取ってから最大1分遅らせて取りに行く。
/// そのため、リンク先だけのカードを出している投稿を初めて見てから、`delays`の間をおいて取り直す。
/// 画面に出ていない投稿は取り直さず、また見えたときに、過ぎた分をまとめて1回取り直す。
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

    /// 初めて見てから、何秒後に取り直すか。最後は、ほかのサーバーの投稿の、最大1分の遅れと取得の時間を待つ。
    public static let delays: [TimeInterval] = [3, 15, 70]
    /// 作られてから（編集した投稿は編集してから）これより経った投稿は、サーバーがカードを付け終えたとみなし、取り直さない。
    /// 初めて見てからこれより経った投稿も、見えないまま予定が過ぎたものとして忘れる。
    public static let maximumAge: TimeInterval = 600

    private struct Entry: Sendable {
        let firstSeen: Date
        /// 取り直した回数。
        var attempts: Int

        func nextDate() -> Date? {
            LinkCardRefreshSchedule.delays.indices.contains(attempts)
                ? firstSeen.addingTimeInterval(LinkCardRefreshSchedule.delays[attempts])
                : nil
        }
    }

    private var entries: [Version: Entry] = [:]
    /// 取り直し終えた版。カードが届いたか、決めた回数を取り直したか、サーバーにもうない。
    private var finished: Set<Version> = []

    public init() {}

    /// リンク先だけのカードを出している投稿を見た。初めて見た投稿の予定を立てる。ブーストなら、ブーストされた投稿を渡す。
    public mutating func note(_ statuses: [Status], now: Date) {
        for status in statuses {
            let version = Version(status)
            guard entries[version] == nil, !finished.contains(version), case .link = LinkCard(status: status),
                  now.timeIntervalSince(status.editedAt ?? status.createdAt) <= Self.maximumAge
            else { continue }
            entries[version] = Entry(firstSeen: now, attempts: 0)
        }
    }

    /// `now`の時点で取り直す投稿。見えている投稿のうち、予定を過ぎたものを、初めて見た順に`limit`件まで返し、取り直したことにする。
    public mutating func due(now: Date, visible: Set<Version>, limit: Int) -> [Version] {
        forgetExpired(now: now)
        let due = entries
            .filter { id, entry in visible.contains(id) && (entry.nextDate().map { $0 <= now } ?? false) }
            .sorted { $0.value.firstSeen == $1.value.firstSeen ? $0.key.statusID < $1.key.statusID : $0.value.firstSeen < $1.value.firstSeen }
            .prefix(limit)
            .map(\.key)
        for id in due {
            guard var entry = entries[id] else { continue }
            // 見えない間に過ぎた予定はまとめて1回にし、次は`now`より後の予定にする。
            entry.attempts += 1
            while let next = entry.nextDate(), next <= now {
                entry.attempts += 1
            }
            if entry.nextDate() == nil {
                entries[id] = nil
                finished.insert(id)
            } else {
                entries[id] = entry
            }
        }
        return due
    }

    /// 見えている投稿のうち、次に取り直す時刻。なければnil。
    public func nextDate(visible: Set<Version>) -> Date? {
        entries.filter { visible.contains($0.key) }.compactMap { $0.value.nextDate() }.min()
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
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
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

    private func refresh(_ versions: [LinkCardRefreshSchedule.Version]) async {
        let ids = versions.map(\.statusID)
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
            let finishedIDs = Set(carded.map(\.id)).union(Set(ids).subtracting(statuses.map(\.id)))
            schedule.finish(versions.filter { finishedIDs.contains($0.statusID) })
            logger.info("link card refresh requested=\(ids.count, privacy: .public) carded=\(carded.count, privacy: .public)")
        } catch is FeatureUnavailable {
            isUnsupported = true
        } catch {
            logger.error("link card refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
