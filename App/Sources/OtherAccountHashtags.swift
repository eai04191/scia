import Foundation
import os
import SciaCore

/// 「別のアカウントで」のハッシュタグのメニューで、ほかのアカウントのフォロー、ミュート、プロフィールでの紹介を読んで変える。決まりはdocs/other-accounts.mdにある。
/// 状態は今のアカウントと同じく、そのアカウントのハッシュタグを覚えてメニューを組み、開くたびに再読み込みする。
/// 今のアカウントのハッシュタグやタブ、投稿欄の補完、プロフィールは変えない。失敗は、このセッションのログインし直しの案内につなげずに知らせる。
@MainActor
final class OtherAccountHashtags {
    private let client: MastodonClient
    private let tasks: TaskScope
    private let now: () -> Date
    private let followed: LatestValueCache<[Hashtag]>
    private let featured: LatestValueCache<[FeaturedTag]>
    private let filters: ServerFilterCache
    private let logger = SciaLog.logger(category: "otherAccountHashtags")

    /// 済んだことと失敗を伝えるコールバック。文言の初めに、どのアカウントで行ったかは入れていない。
    /// 状態はウィンドウをまたいで共有するが、結果は操作したウィンドウに出すので、操作ごとに渡す。
    struct Report {
        var done: @MainActor (String) -> Void
        var failure: @MainActor (String, any Error) -> Void
    }

    /// - Parameter tasks: 送る処理を始める、そのアカウントの持ち主。ログアウトで、キャッシュの通信と一緒に止める。
    init(client: MastodonClient, tasks: TaskScope, now: @escaping () -> Date = AppDependencies.now) {
        self.client = client
        self.tasks = tasks
        self.now = now
        let followed = LatestValueCache<[Hashtag]>(label: "otherAccountFollowedTags") { try await client.followedTags() }
        let featured = LatestValueCache<[FeaturedTag]>(label: "otherAccountFeaturedTags") { try await client.featuredTags() }
        let filters = ServerFilterCache(label: "otherAccountFilters") { try await client.filters() }
        self.followed = followed
        self.featured = featured
        self.filters = filters
        tasks.onClose { [weak followed, weak featured, weak filters] in
            followed?.close()
            featured?.close()
            filters?.close()
        }
    }

    /// 済んだことと失敗を`report`に知らせる操作。
    func actions(report: Report) -> HashtagMenuActions {
        let followed = followed
        let featured = featured
        let filters = filters
        let now = now
        return HashtagMenuActions(
            mute: HashtagMuteActions(
                known: { name in filters.value.map { HashtagMute.find(name, in: $0, now: now()) != nil } },
                // まだ読めていなければ、開いたメニューがこの再読み込みを待つので、操作として送る。
                refresh: { filters.refresh(purpose: .action) },
                load: { name in HashtagMute.find(name, in: try await filters.latest(), now: now()) != nil },
                mute: { [weak self] name, duration in self?.mute(name, duration: duration, report: report) },
                unmute: { [weak self] name in self?.unmute(name, report: report) }
            ),
            follow: HashtagToggleActions(
                known: { name in followed.value.map { $0.contains(named: name) } },
                refresh: { followed.refresh(purpose: .action) },
                load: { name in try await followed.latest().contains(named: name) },
                turnOn: { [weak self] name in self?.follow(name, report: report) },
                turnOff: { [weak self] name in self?.unfollow(name, report: report) }
            ),
            feature: HashtagToggleActions(
                known: { name in featured.value.map { $0.first(named: name) != nil } },
                refresh: { featured.refresh(purpose: .action) },
                load: { name in try await featured.latest().first(named: name) != nil },
                turnOn: { [weak self] name in self?.feature(name, report: report) },
                turnOff: { [weak self] name in self?.unfeature(name, report: report) }
            )
        )
    }

    private func follow(_ name: String, report: Report) {
        send(key: "follow:\(name)", done: HashtagChangeTexts.followed(name), failure: HashtagChangeTexts.followFailure, reloading: followed, report: report) { client in
            try await client.followTag(name)
        }
    }

    private func unfollow(_ name: String, report: Report) {
        send(key: "follow:\(name)", done: HashtagChangeTexts.unfollowed(name), failure: HashtagChangeTexts.unfollowFailure, reloading: followed, report: report) { client in
            try await client.unfollowTag(name)
        }
    }

    private func feature(_ name: String, report: Report) {
        send(key: "feature:\(name)", done: HashtagChangeTexts.featured(name), failure: HashtagChangeTexts.featureFailure, reloading: featured, report: report) { client in
            _ = try await client.featureTag(name)
        }
    }

    /// 外すIDは、外すときに再読み込みしたハッシュタグで決める。今のアカウントで外すときと同じく、別の端末で足し直したタグを古いIDで消さないため。
    private func unfeature(_ name: String, report: Report) {
        let featured = featured
        send(key: "feature:\(name)", done: HashtagChangeTexts.unfeatured(name), failure: HashtagChangeTexts.featureFailure, reloading: featured, report: report) { client in
            featured.reload(purpose: .action)
            if let tag = try await featured.latest().first(named: name) {
                try await client.unfeatureTag(tag.id)
            }
        }
    }

    private func mute(_ name: String, duration: Duration?, report: Report) {
        send(key: "mute:\(name)", done: HashtagChangeTexts.muted(name), failure: HashtagChangeTexts.muteFailure, reloading: filters, report: report) { client in
            try await HashtagMute.mute(name, duration: duration, client: client)
        }
    }

    /// 解く条件は、解除するときにフィルターを再読み込みして決める。今のアカウントで解除するときと同じく、ほかで足した条件まで消さないため。
    private func unmute(_ name: String, report: Report) {
        let filters = filters
        let now = now
        send(key: "mute:\(name)", done: HashtagChangeTexts.unmuted(name), failure: HashtagChangeTexts.muteFailure, reloading: filters, report: report) { client in
            filters.reload(purpose: .action)
            if let muted = HashtagMute.find(name, in: try await filters.latest(), now: now()) {
                try await muted.unmute(client: client)
            }
        }
    }

    /// 送り終える前にメニューを開き直して選択しても、同じ要求を重ねて送らない。済んでも失敗しても、キャッシュしているハッシュタグを再読み込みする。
    /// 失敗しても、応答が届かなかっただけで変わっていることがあるため。
    private func send<Value>(key: String, done: String, failure: String, reloading cache: LatestValueCache<Value>, report: Report, _ operation: @escaping @MainActor (MastodonClient) async throws -> Void) {
        let client = client
        tasks.run(key: key, .skippingWhileRunning, .action) { [weak self] in
            do {
                try await operation(client)
                cache.reload(purpose: .action)
                report.done(done)
            } catch {
                cache.reload(purpose: .action)
                self?.logger.error("other account hashtag change failed: \(SciaLog.describe(error), privacy: .public)")
                report.failure(failure, error)
            }
        }
    }
}
