public import Foundation

/// 問い合わせずに出す、メンションの候補。返信先の人と、補完で選んだことのある人。
/// Mastodonには最近やり取りした人を返すAPIがないため、手元で集める。返信先のメンションされた人は、アイコンや表示名を持たない。
public struct LocalMention: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let acct: String
    /// 分からなければ空。
    public let displayName: String
    public let avatar: URL?
    public let emojis: [CustomEmoji]

    public init(account: Account) {
        id = account.id
        username = account.username
        acct = account.acct
        displayName = account.displayName
        avatar = account.avatarStatic ?? account.avatar
        emojis = account.emojis
    }

    public init(mention: Mention) {
        id = mention.id
        username = mention.username
        acct = mention.acct
        displayName = ""
        avatar = nil
        emojis = []
    }

    public var displayNameOrUsername: String {
        displayName.isEmpty ? username : displayName
    }

    /// 表示名かアイコンを持つ。返信先でメンションされた人は、どちらも持たない。
    var hasProfile: Bool {
        !displayName.isEmpty || avatar != nil
    }

    /// 返信先の投稿の、投稿した人とメンションされた人。自分を除き、同じ人は一度だけ、返信の下書きに入れる順で並べる。
    public static func replyParticipants(of status: Status, myAccountID: String) -> [LocalMention] {
        let target = status.displayed
        var seen: Set<String> = []
        return ([LocalMention(account: target.account)] + target.mentions.map(LocalMention.init(mention:)))
            .filter { $0.id != myAccountID && seen.insert($0.id).inserted }
    }

    /// ハンドルが語で始まるものを先に、ハンドルか表示名が語を含むものを後に並べる。大文字小文字は区別しない。
    /// それぞれの中は`mentions`の順のまま。語が空なら全部を返す。
    public static func matching(_ query: String, in mentions: [LocalMention]) -> [LocalMention] {
        let query = query.lowercased()
        guard !query.isEmpty else { return mentions }
        let prefixed = mentions.filter { $0.acct.lowercased().hasPrefix(query) }
        let contained = mentions.filter { mention in
            !mention.acct.lowercased().hasPrefix(query) && (mention.acct.lowercased().contains(query) || mention.displayName.lowercased().contains(query))
        }
        return prefixed + contained
    }
}

/// 補完で選んだアカウントを、ログインしているアカウントごとに新しい順で覚える。
/// `RecentEmojis`と同じく、複数のウィンドウで開いても上書きし合わないよう、手元に持たずに毎回UserDefaultsを読み書きする。
@MainActor
public final class RecentMentions {
    private let defaults: UserDefaults
    private let key: String
    /// 覚えておく人数。
    public static let capacity = 20

    public init(defaults: UserDefaults, credentialID: String) {
        self.defaults = defaults
        key = "compose.recentMentions.\(credentialID)"
    }

    /// 新しい順。読めなければ空。
    public var mentions: [LocalMention] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LocalMention].self, from: data)) ?? []
    }

    /// 表示名とアイコンを持たない人（返信先でメンションされた人）を選んだときは、覚えている同じ人の情報を残し、並びだけを先頭にする。
    public func record(_ mention: LocalMention) {
        var mentions = mentions
        let remembered = mentions.first { $0.id == mention.id }
        mentions.removeAll { $0.id == mention.id }
        mentions.insert(mention.hasProfile ? mention : remembered ?? mention, at: 0)
        guard let data = try? JSONEncoder().encode(Array(mentions.prefix(Self.capacity))) else { return }
        defaults.set(data, forKey: key)
    }
}
