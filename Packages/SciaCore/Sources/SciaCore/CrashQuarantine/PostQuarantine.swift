public import Foundation

/// クラッシュしたときに処理していた投稿のリスト。決まりはdocs/crash-quarantine.mdにある。
///
/// ビルドが変わると空にする。直ったあとも隠したままにしないため。
@MainActor
public final class PostQuarantine {
    private struct Post: Codable, Hashable {
        var accountID: String
        var statusID: String
    }

    private struct Stored: Codable {
        var build: String
        var posts: [Post]
        var unnotified: [Post]
    }

    private static let key = "crashQuarantine"
    private let defaults: UserDefaults
    private var stored: Stored
    private var lookup: Set<String>
    /// 前の起動とビルドが違う。前の起動のクラッシュの記録は、前のビルドのものなので隔離に使わない。
    public let isNewBuild: Bool

    public init(defaults: UserDefaults, build: String) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        stored = saved?.build == build ? saved ?? Stored(build: build, posts: [], unnotified: []) : Stored(build: build, posts: [], unnotified: [])
        lookup = Set(stored.posts.map(\.statusID))
        isNewBuild = saved?.build != build
        if isNewBuild {
            save()
        }
    }

    public func add(accountID: String, statusID: String) {
        let post = Post(accountID: accountID, statusID: statusID)
        guard !stored.posts.contains(post) else { return }
        lookup.insert(statusID)
        stored.posts.append(post)
        stored.unnotified.append(post)
        save()
    }

    /// 複数のウィンドウで別のアカウントを開けるので、行を描くときはアカウントを問わずに引く。別のサーバーの投稿のIDと重なっても、次のビルドまでその行が隠れるだけで済む。
    public func contains(statusID: String) -> Bool {
        lookup.contains(statusID)
    }

    /// まだ使う人に伝えていない投稿のIDを返し、伝えたことにする。
    public func takeUnnotified(accountID: String) -> [String] {
        let taken = stored.unnotified.filter { $0.accountID == accountID }
        guard !taken.isEmpty else { return [] }
        stored.unnotified.removeAll { $0.accountID == accountID }
        save()
        return taken.map(\.statusID)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
