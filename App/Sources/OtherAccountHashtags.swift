import Foundation
import os
import SciaCore

/// 「別のアカウントで」のハッシュタグのメニューで、ほかのアカウントのフォロー、ミュート、プロフィールでの紹介を読んで変える。決まりはdocs/menus.mdにある。
/// 状態は今のアカウントと同じく、そのアカウントのハッシュタグを覚えてメニューを組み、開くたびに読み直す。
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
    /// 済んだことを知らせる。文言の初めに、どのアカウントで行ったかは入れていない。
    var onDone: (String) -> Void = { _ in }
    /// 失敗を知らせる。見出しの初めに、どのアカウントで行ったかは入れていない。
    var onFailure: (String, any Error) -> Void = { _, _ in }

    /// - Parameter tasks: 送る処理を始めるセッションの持ち主。ログアウトやアカウントの切り替えで、キャッシュの通信と一緒に止める。
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

    var actions: HashtagMenuActions {
        let followed = followed
        let featured = featured
        let filters = filters
        let now = now
        return HashtagMenuActions(
            mute: HashtagMuteActions(
                known: { name in filters.value.map { HashtagMute.find(name, in: $0, now: now()) != nil } },
                // まだ読めていなければ、開いたメニューがこの読み直しを待つので、操作として送る。
                refresh: { filters.refresh(purpose: .action) },
                load: { name in HashtagMute.find(name, in: try await filters.latest(), now: now()) != nil },
                mute: { [weak self] name, duration in self?.mute(name, duration: duration) },
                unmute: { [weak self] name in self?.unmute(name) }
            ),
            follow: HashtagToggleActions(
                known: { name in followed.value.map { $0.contains(named: name) } },
                refresh: { followed.refresh(purpose: .action) },
                load: { name in try await followed.latest().contains(named: name) },
                turnOn: { [weak self] name in self?.follow(name) },
                turnOff: { [weak self] name in self?.unfollow(name) }
            ),
            feature: HashtagToggleActions(
                known: { name in featured.value.map { $0.first(named: name) != nil } },
                refresh: { featured.refresh(purpose: .action) },
                load: { name in try await featured.latest().first(named: name) != nil },
                turnOn: { [weak self] name in self?.feature(name) },
                turnOff: { [weak self] name in self?.unfeature(name) }
            )
        )
    }

    private func follow(_ name: String) {
        send(key: "follow:\(name)", done: "#\(name)をフォローしました", failure: "ハッシュタグをフォローできませんでした", reloading: followed) { client in
            try await client.followTag(name)
        }
    }

    private func unfollow(_ name: String) {
        send(key: "follow:\(name)", done: "#\(name)のフォローを外しました", failure: "ハッシュタグのフォローを外せませんでした", reloading: followed) { client in
            try await client.unfollowTag(name)
        }
    }

    private func feature(_ name: String) {
        send(key: "feature:\(name)", done: "#\(name)をプロフィールで紹介しました", failure: "プロフィールでの紹介を変更できませんでした", reloading: featured) { client in
            _ = try await client.featureTag(name)
        }
    }

    /// 外すIDは、外すときに読み直したハッシュタグで決める。今のアカウントで外すときと同じく、別の端末で足し直したタグを古いIDで消さないため。
    private func unfeature(_ name: String) {
        let featured = featured
        send(key: "feature:\(name)", done: "#\(name)をプロフィールから外しました", failure: "プロフィールでの紹介を変更できませんでした", reloading: featured) { client in
            featured.reload(purpose: .action)
            if let tag = try await featured.latest().first(named: name) {
                try await client.unfeatureTag(tag.id)
            }
        }
    }

    private func mute(_ name: String, duration: Duration?) {
        send(key: "mute:\(name)", done: "#\(name)をミュートしました", failure: "ミュートを変更できませんでした", reloading: filters) { client in
            try await HashtagMute.mute(name, duration: duration, client: client)
        }
    }

    /// 解く条件は、解除するときにフィルターを読み直して決める。今のアカウントで解除するときと同じく、ほかで足した条件まで消さないため。
    private func unmute(_ name: String) {
        let filters = filters
        let now = now
        send(key: "mute:\(name)", done: "#\(name)のミュートを解除しました", failure: "ミュートを変更できませんでした", reloading: filters) { client in
            filters.reload(purpose: .action)
            if let muted = HashtagMute.find(name, in: try await filters.latest(), now: now()) {
                try await muted.unmute(client: client)
            }
        }
    }

    /// 送り終える前にメニューを開き直して押しても、同じ要求を重ねて送らない。済んでも失敗しても、覚えているハッシュタグを読み直す。
    /// 失敗しても、応答が届かなかっただけで変わっていることがあるため。
    private func send<Value>(key: String, done: String, failure: String, reloading cache: LatestValueCache<Value>, _ operation: @escaping @MainActor (MastodonClient) async throws -> Void) {
        let client = client
        tasks.run(key: key, .skippingWhileRunning, .action) { [weak self] in
            do {
                try await operation(client)
                cache.reload(purpose: .action)
                self?.onDone(done)
            } catch {
                cache.reload(purpose: .action)
                self?.logger.error("other account hashtag change failed: \(SciaLog.describe(error), privacy: .public)")
                self?.onFailure(failure, error)
            }
        }
    }
}
