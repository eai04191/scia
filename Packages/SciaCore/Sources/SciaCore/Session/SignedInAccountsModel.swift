public import Foundation
public import Observation
import os

/// 「アカウントを管理」の画面に並べるアカウントと、それぞれの読めたプロフィールと、ログアウトされたか。決まりはdocs/account-screen.mdの「アカウントを管理」にある。
@MainActor
@Observable
public final class SignedInAccountsModel {
    public struct Row: Identifiable, Sendable {
        public let credential: Credential
        public let isCurrent: Bool
        /// 読めたプロフィール。読めるまでと読めなかったときはnil。
        public let profile: Account?
        /// 今の資格情報で401が返った。
        public let isLoggedOut: Bool

        public var id: Credential.ID { credential.id }

        /// 行の名前。読めるまでは`@username`。
        public var name: String { profile?.displayNameOrUsername ?? "@\(credential.username)" }

        /// 名前に入るカスタム絵文字。自分のアカウントの`acct`にはサーバー名がないので、ログインしたサーバーの絵文字とする。
        public var emojis: [CustomEmoji] {
            (profile?.emojis ?? []).map { emoji in
                var emoji = emoji
                if emoji.domain == nil { emoji.domain = credential.server }
                return emoji
            }
        }
    }

    @ObservationIgnored private let registry: AccountRegistry
    @ObservationIgnored private let currentID: Credential.ID?
    @ObservationIgnored private let loadProfile: @MainActor (Credential) -> @Sendable () async throws -> Account
    @ObservationIgnored private let logIn: @MainActor (Credential) async -> Void
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let logger = SciaLog.logger(category: "signedInAccounts")
    private var profiles: [Credential.ID: Account] = [:]
    /// 401が返ったときの資格情報。ログインし直してトークンが替わったら、ログアウトされたとは見なさない。
    private var loggedOut: [Credential.ID: Credential] = [:]

    /// - Parameters:
    ///   - currentID: チェックマークを付けるアカウント。ダミーのアカウントを出している間はnil。
    ///   - loadProfile: そのアカウントのトークンで、そのアカウント自身を読むもの。トークンが無効なら401の`MastodonAPIError`を投げる。
    ///   - logIn: そのアカウントにログインし直す。使うアカウントは替えない。
    ///   - tasks: 読み込みを始める持ち主。
    public init(
        registry: AccountRegistry,
        currentID: Credential.ID?,
        tasks: TaskScope,
        loadProfile: @escaping @MainActor (Credential) -> @Sendable () async throws -> Account,
        logIn: @escaping @MainActor (Credential) async -> Void
    ) {
        self.registry = registry
        self.currentID = currentID
        self.tasks = tasks
        self.loadProfile = loadProfile
        self.logIn = logIn
    }

    public var rows: [Row] {
        registry.accounts.map { credential in
            Row(
                credential: credential,
                isCurrent: credential.id == currentID,
                profile: profiles[credential.id],
                isLoggedOut: loggedOut[credential.id] == credential
            )
        }
    }

    /// すべてのアカウントを読み直す。読み直している間は、前に読めたものを出したままにする。
    public func reload() {
        for credential in registry.accounts {
            load(credential)
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        registry.move(fromOffsets: source, toOffset: destination)
    }

    /// そのアカウントにログインし直し、済んだら読み直す。
    public func logIn(_ id: Credential.ID) {
        guard let credential = registry.accounts.first(where: { $0.id == id }) else { return }
        tasks.run(.action) { [weak self] in
            guard let self else { return }
            await logIn(credential)
            guard let renewed = registry.accounts.first(where: { $0.id == id }) else { return }
            load(renewed)
        }
    }

    private func load(_ credential: Credential) {
        let fetch = loadProfile(credential)
        let id = credential.id
        tasks.run(key: "profile \(id)", .replacing, .display) { [weak self] in
            do {
                let account = try await fetch()
                guard let self, !Task.isCancelled else { return }
                profiles[id] = account
                loggedOut[id] = nil
            } catch let error as MastodonAPIError where error.isUnauthorized {
                self?.loggedOut[id] = credential
            } catch {
                self?.logger.error("signedInAccounts load failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }
}
