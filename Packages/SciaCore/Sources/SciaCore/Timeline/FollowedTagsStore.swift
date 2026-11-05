import Foundation

/// 「フォロー中のハッシュタグ」の一覧を、サーバーが返す順に持つ。決まりはdocs/tabs.mdの「フォロー中のハッシュタグ」にある。
/// 一覧は続きを最後まで読み切ってから入れる。ハッシュタグのメニューがフォローしているかを決めるのと同じ一覧を使うため。
@MainActor
public final class FollowedTagsStore {
    public typealias Fetch = @MainActor () async throws -> [Hashtag]

    /// サーバーが返す順。サーバーと同じ決まりでそろえた名前が同じタグは1度だけ並べる。
    public private(set) var tags: [Hashtag] = []
    /// 一度でも読めたか。
    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    private let fetch: Fetch
    /// 読んでいる間にアプリの中でフォローしたり外したりしたタグ。読み始めた時点の応答には入っていないことがあるので、応答を入れたあとにやり直す。
    private var changesDuringLoad: [Change] = []

    private enum Change {
        case follow(Hashtag)
        case unfollow(String)
    }

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 読み直して置き換える。読み込み中なら何もせずfalseを返す。読めなければ投げ、前の一覧を残す。
    public func load() async throws -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        changesDuringLoad = []
        replace(with: try await fetch())
        for change in changesDuringLoad {
            apply(change)
        }
        changesDuringLoad = []
        return true
    }

    /// ほかで読み直した一覧で置き換える。ハッシュタグのメニューを開いたときの読み直しも、一覧に効かせるため。
    /// 読み込み中なら、その読み込みに任せて受け取らずfalseを返す。読み込みの応答も同じ読み直しの結果になるため。
    public func receive(_ loaded: [Hashtag]) -> Bool {
        guard !isLoading else { return false }
        replace(with: loaded)
        return true
    }

    private func replace(with loaded: [Hashtag]) {
        var seen: Set<String> = []
        tags = loaded.filter { seen.insert(Hashtag.normalizedName($0.name)).inserted }
        isLoaded = true
    }

    /// アプリの中でフォローしたタグを、読み直すのを待たずに先頭に入れる。もう並んでいれば何もしない。
    public func didFollow(_ tag: Hashtag) {
        record(.follow(tag))
    }

    /// アプリの中でフォローを外したタグを、読み直すのを待たずに除く。
    public func didUnfollow(_ name: String) {
        record(.unfollow(name))
    }

    private func record(_ change: Change) {
        if isLoading { changesDuringLoad.append(change) }
        apply(change)
    }

    private func apply(_ change: Change) {
        switch change {
        case .follow(let tag):
            guard !tags.contains(named: tag.name) else { return }
            tags.insert(tag, at: 0)
        case .unfollow(let name):
            let normalized = Hashtag.normalizedName(name)
            tags.removeAll { Hashtag.normalizedName($0.name) == normalized }
        }
    }
}
