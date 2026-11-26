import Foundation
import os
import SciaCore

/// 「フォロー中のハッシュタグ」の読み込みを、TimelineViewControllerの表示へつなぐ。決まりはdocs/tabs.mdの「フォロー中のハッシュタグ」にある。
/// 行は検索の結果のハッシュタグの行と同じもので、選択したときと長押ししたときの動きは、画面を組むセッションが決める。
@MainActor
final class FollowedTagsController {
    private(set) lazy var viewController = TimelineViewController(texts: .followedTags, settings: settings) { [weak self] in await self?.refresh() }
    private let store: FollowedTagsStore
    private let followedTags: LatestValueCache<[Hashtag]>
    /// この画面が始めた処理の持ち主。セッションの持ち主の子で、ログアウトやアカウントの切り替えで止まる。
    private let tasks: TaskScope
    private let logger = SciaLog.logger(category: "followedTags")
    /// タブで見せているか。見せ始めたときに再読み込みする。
    private var isShown = false

    /// `session`の部品で作り、`session`に登録する。電波の回復などのやり直しと、トークンが無効と分かったときに止めるのを`session`から受け取る。
    /// - Parameter followedTags: ハッシュタグのメニューがフォローしているかを決めるのと同じ、フォロー中のハッシュタグ。どちらで再読み込みしても、もう一方に効く。
    private let settings: AppSettings

    init(followedTags: LatestValueCache<[Hashtag]>, session: AccountSession) {
        settings = session.settings
        tasks = session.tasks.child()
        self.followedTags = followedTags
        // 再読み込みは、始める側が通信の目的を名乗って始める（`loadNow`）。ここでは、いちばん新しい再読み込みの結果を受け取る。
        store = FollowedTagsStore { try await followedTags.latest() }
        viewController.onRetry = { [weak self] in self?.load(purpose: .action) }
        session.register(self)
    }

    /// メニューを開いたときなど、ほかで再読み込みしたハッシュタグを出す。読み込み中なら、その読み込みが出す。
    /// 再読み込みした結果を受け取れるのは1つだけなので、画面を組むセッションが受け取って、開いている画面すべてに渡す。
    func cacheDidLoad(_ tags: [Hashtag]) {
        guard store.receive(tags) else { return }
        show()
    }

    /// タブで見せ始めたか、見せなくなったかを伝える。見せ始めたら、ほかの端末やwebで変えたフォローを拾うため再読み込みする。
    func setShown(_ shown: Bool) {
        defer { isShown = shown }
        guard shown, !isShown else { return }
        load(purpose: .action)
    }

    /// バックグラウンドから戻ったときに呼ぶ。見せていれば再読み込みする。
    func enterForeground() {
        guard isShown else { return }
        load(purpose: .display)
    }

    /// アプリの中でフォローしたタグを、再読み込みするのを待たずに先頭に入れる。
    func didFollow(_ tag: Hashtag) {
        store.didFollow(tag)
        if store.isLoaded { show() }
    }

    /// アプリの中でフォローを外したタグを、再読み込みするのを待たずに除く。使う人の操作で消えるので、閉じる動きで消す。
    func didUnfollow(_ name: String) {
        store.didUnfollow(name)
        if store.isLoaded { show(animatesRemoval: true) }
    }

    /// まだ読めていなければ読み込み中の表示を出して読む。読めていれば、前に読んだハッシュタグを出したまま再読み込みする。
    private func load(purpose: RequestPurpose) {
        if !store.isLoaded {
            viewController.setContentState(.loading)
        }
        tasks.run(purpose) { [weak self] in
            await self?.loadNow(purpose: purpose, during: "load")
        }
    }

    /// pull to refreshしたときに再読み込みする。読めなければ前に読んだものを残す。
    private func refresh() async {
        logger.info("followedTags refresh")
        await loadNow(purpose: .action, during: "refresh")
    }

    private func loadNow(purpose: RequestPurpose, during operation: String) async {
        // 読み込み中なら、走っている読み込みに任せる。重ねて再読み込みすると、同じものを2回読むため。
        guard !store.isLoading else { return }
        followedTags.reload(purpose: purpose)
        do {
            guard try await store.load() else { return }
            show()
            logger.info("followedTags \(operation, privacy: .public) done count=\(self.store.tags.count, privacy: .public)")
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            logger.error("followedTags \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
            // 読めているハッシュタグは残す。まだ読めていなければ、失敗の表示とやり直すボタンを出す。
            if !store.isLoaded {
                viewController.setContentState(.failed(ErrorPresentation(error)))
            }
        }
    }

    /// 末尾の「フォローしているハッシュタグはありません」は、行の有無で出し分けるので、行を変えたら終わりまで読んだことも伝え直す。
    private func show(animatesRemoval: Bool = false) {
        viewController.setEntries(store.tags.map { .search(.hashtag($0)) }, animatesRemoval: animatesRemoval)
        viewController.setContentState(.loaded)
        viewController.setFooterState(.reachedEnd)
    }
}

extension FollowedTagsController: SessionList {
    /// 電波が戻ったときや、レート制限が明けたときに、読めないままのハッシュタグを再読み込みする。
    func recover() {
        guard case .failed = viewController.contentState else { return }
        load(purpose: .display)
    }

    /// トークンが無効と分かったら、読み込みを打ち切り、以後は読まない。
    func stop() {
        tasks.close()
    }
}
