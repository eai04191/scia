public import Foundation
public import Observation

@MainActor
@Observable
public final class UserDisplay {
    struct Source: Equatable {
        var name: String
        var emojis: [CustomEmoji]
        var avatar: URL?
        var avatarStatic: URL?
        var avatarDescription: String?

        init(_ account: Account, localServer: String?) {
            name = account.displayNameOrUsername
            emojis = Self.qualified(account.emojis, localServer: account.emojiDomain ?? localServer)
            avatar = account.avatar
            avatarStatic = account.avatarStatic
            avatarDescription = account.avatarDescription
        }

        init(_ mention: LocalMention, localServer: String?) {
            name = mention.displayNameOrUsername
            emojis = Self.qualified(mention.emojis, localServer: Account.emojiDomain(ofAcct: mention.acct) ?? localServer)
            avatar = mention.avatar
            avatarStatic = mention.avatar
        }

        private static func qualified(_ emojis: [CustomEmoji], localServer: String?) -> [CustomEmoji] {
            emojis.map { emoji in
                var emoji = emoji
                if emoji.domain == nil { emoji.domain = localServer }
                return emoji
            }
        }

        init(handle: String) {
            name = String(handle.prefix(while: { $0 != "@" }))
            emojis = []
        }
    }

    public struct Avatar: Equatable {
        public let url: URL?
        public let animates: Bool
    }

    public struct Snapshot: Equatable {
        public let name: String
        public let emojis: [CustomEmoji]
        public let avatar: URL?
        public let avatarStatic: URL?
        public let stopsAnimation: Bool
    }

    public var snapshot: Snapshot {
        Snapshot(name: name, emojis: emojis, avatar: avatar, avatarStatic: avatarStatic, stopsAnimation: stopsAnimation)
    }

    private let persistence: SettingsStore
    private let localServer: String?
    public let handle: String
    private var source: Source
    private var isAccount = false
    private var redirected: UserDisplay?
    private var sourceVersion = 0
    private var effectiveSource: Source { redirected?.effectiveSource ?? source }
    private var version: Int { redirected?.version ?? sourceVersion }
    var hasAccount: Bool { redirected?.hasAccount ?? isAccount }

    init(handle: String, source: Source, settings: AppSettings) {
        self.handle = handle
        self.source = source
        persistence = settings.store
        localServer = settings.emojiLocalServer
    }

    var key: String? {
        if handle.contains("@") { return handle.lowercased() }
        guard let localServer, let domain = persistence.userDisplayDomains[localServer.lowercased()] else { return nil }
        return "\(handle)@\(domain)".lowercased()
    }

    public var rule: UserDisplayRule {
        key.flatMap { persistence.userDisplayRules[$0] } ?? UserDisplayRule()
    }

    public var name: String { rule.name ?? effectiveSource.name }
    public var emojis: [CustomEmoji] { rule.name == nil ? effectiveSource.emojis : [] }
    public var avatar: URL? { customAvatar ?? effectiveSource.avatar }
    public var avatarStatic: URL? { customAvatar ?? effectiveSource.avatarStatic }
    public var stopsAnimation: Bool { rule.stopsAnimation }
    public var warning: String? { UserDisplayTexts.customizationWarning(for: rule) }
    public var customAvatar: URL? {
        rule.avatarFile.map { persistence.userDisplayImageDirectory.appending(fileName: SafeFileName($0)) }
    }

    public func avatar(animates: Bool) -> Avatar {
        let plays = animates && !stopsAnimation && customAvatar == nil
        return Avatar(url: plays ? avatar : avatarStatic, animates: plays)
    }

    public func attachment(of image: ProfileImage, original account: Account) -> MediaAttachment? {
        guard image == .avatar else { return account.attachment(of: image) }
        let shown = avatar(animates: true)
        guard let url = shown.url ?? avatarStatic else { return nil }
        let id = customAvatar == nil ? "account:\(account.id):avatar" : "user-display:\(account.id)"
        return MediaAttachment(id: id, type: .image, url: url, previewUrl: avatarStatic ?? url, description: customAvatar == nil ? effectiveSource.avatarDescription : nil)
    }

    @discardableResult
    func receive(_ account: Account, localServer: String?, version: Int) -> Bool {
        if let redirected { return redirected.receive(account, localServer: localServer, version: version) }
        let next = Source(account, localServer: localServer)
        let changed = source != next
        if changed { source = next }
        sourceVersion = version
        isAccount = true
        return changed
    }

    func hydrate(_ mention: LocalMention, localServer: String?) {
        if let redirected { redirected.hydrate(mention, localServer: localServer); return }
        guard !isAccount, mention.hasProfile else { return }
        let next = Source(mention, localServer: localServer)
        if source != next { source = next }
    }

    func redirect(to canonical: UserDisplay) {
        guard canonical !== self else { return }
        if version > canonical.version {
            canonical.source = effectiveSource
            canonical.sourceVersion = version
            canonical.isAccount = hasAccount
        }
        redirected = canonical
    }
}
