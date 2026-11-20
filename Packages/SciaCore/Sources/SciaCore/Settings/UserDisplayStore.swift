public import Foundation
public import Observation
import CryptoKit
import MemoryCache
import os

@MainActor
@Observable
public final class UserDisplayStore {
    private struct WeakDisplay { weak var value: UserDisplay? }
    private struct AccountSource {
        weak var accounts: AccountCache?
        weak var settings: AppSettings?
    }

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var displays: [String: WeakDisplay] = [:]
    @ObservationIgnored private var sources: [ObjectIdentifier: AccountSource] = [:]
    @ObservationIgnored private var retained = CostLimitedCache<String, UserDisplay>(totalCostLimit: ReceivedAccounts.limit)
    @ObservationIgnored private var sourceVersion = 0
    private var revision = 0

    init(store: SettingsStore) { self.store = store }

    public var rules: [String: UserDisplayRule] { store.userDisplayRules }

    public func observeChanges() {
        _ = revision
        _ = store.userDisplayRules
        _ = store.userDisplayDomains
    }

    public func display(of account: Account, in settings: AppSettings) -> UserDisplay {
        observeChanges()
        let latest = sources.values.first { $0.settings === settings }?.accounts?.latest(of: account) ?? account
        let display = entry(handle: latest.acct, source: .init(latest, localServer: settings.emojiLocalServer), settings: settings)
        if !display.hasAccount { display.receive(latest, localServer: settings.emojiLocalServer, version: sourceVersion) }
        return display
    }

    public func display(of mention: LocalMention, in settings: AppSettings) -> UserDisplay {
        observeChanges()
        if let account = sources.values.first(where: { $0.settings === settings })?.accounts?.account(mention.id) {
            return display(of: account, in: settings)
        }
        let display = entry(handle: mention.acct, source: .init(mention, localServer: settings.emojiLocalServer), settings: settings)
        display.hydrate(mention, localServer: settings.emojiLocalServer)
        return display
    }

    public func display(for handle: String, in settings: AppSettings) -> UserDisplay {
        observeChanges()
        for source in sources.values {
            guard let context = source.settings,
                  let account = source.accounts?.account(acct: handle, localDomain: context.userDisplayDomain) else { continue }
            return display(of: account, in: context)
        }
        return entry(handle: handle, source: .init(handle: handle), settings: settings)
    }

    private func entry(handle: String, source: UserDisplay.Source, settings: AppSettings) -> UserDisplay {
        let key = settings.userDisplayKey(acct: handle) ?? "\(settings.userDisplayScope ?? "")/\(handle)"
        let localName = String(handle.prefix(while: { $0 != "@" }))
        let localKey = "\(settings.userDisplayScope ?? "")/\(localName)"
        let alias = settings.userDisplayKey(acct: localName) == key ? displays[localKey]?.value : nil
        if let existing = displays[key]?.value ?? alias {
            alias?.redirect(to: existing)
            displays[key] = WeakDisplay(value: existing)
            retained.setValue(existing, forKey: key, cost: 1)
            return existing
        }
        displays = displays.filter { $0.value.value != nil }
        let display = UserDisplay(handle: handle, source: source, settings: settings)
        displays[key] = WeakDisplay(value: display)
        retained.setValue(display, forKey: key, cost: 1)
        return display
    }

    public func receive(_ account: Account, in settings: AppSettings) {
        sourceVersion += 1
        let latest = sources.values.first { $0.settings === settings }?.accounts?.latest(of: account) ?? account
        let key = settings.userDisplayKey(acct: latest.acct) ?? "\(settings.userDisplayScope ?? "")/\(latest.acct)"
        let existed = displays[key]?.value != nil
        let display = entry(handle: latest.acct, source: .init(latest, localServer: settings.emojiLocalServer), settings: settings)
        let changed = display.receive(latest, localServer: settings.emojiLocalServer, version: sourceVersion)
        if changed || !existed { revision += 1 }
    }

    func reconcileDomains() {
        for item in Array(displays.values) {
            guard let display = item.value, let key = display.key else { continue }
            if let canonical = displays[key]?.value {
                display.redirect(to: canonical)
            } else {
                displays[key] = WeakDisplay(value: display)
            }
        }
        revision += 1
    }

    public func connect(accounts: AccountCache, settings: AppSettings, received: ReceivedAccounts, tasks: TaskScope) {
        let changes = received.changes
        let id = ObjectIdentifier(tasks)
        sources[id] = AccountSource(accounts: accounts, settings: settings)
        tasks.onClose { [weak self] in self?.sources[id] = nil }
        tasks.run(.display) { [weak self, weak accounts] in
            for await batch in changes {
                guard !Task.isCancelled, let self, let accounts else { return }
                for account in batch { receive(accounts.latest(of: account), in: settings) }
            }
        }
    }
    public func save(_ rule: UserDisplayRule, for account: Account, in settings: AppSettings, imageData: Data? = nil) throws {
        guard let key = settings.userDisplayKey(acct: account.acct) else { throw UserDisplayError.missingServer }
        try saveUserDisplay(rule, key: key, imageData: imageData)
    }

    public func remove(forKey key: String) {
        let previous = store.userDisplayRules.removeValue(forKey: key)?.avatarFile
        removeUnusedUserAvatar(previous)
    }

    private func saveUserDisplay(_ rule: UserDisplayRule, key: String, imageData: Data?) throws {
        var rule = rule
        let name = rule.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.name = name?.isEmpty == false ? name : nil
        let directory = store.userDisplayImageDirectory
        if let imageData {
            let hash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            let file = SafeFileName(hash)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try imageData.write(to: directory.appending(fileName: file), options: .atomic)
            rule.avatarFile = file.value
        }
        if let file = rule.avatarFile, !FileManager.default.fileExists(atPath: directory.appending(fileName: SafeFileName(file)).path) {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let previous = store.userDisplayRules[key]?.avatarFile
        store.userDisplayRules[key] = rule.isEmpty ? nil : rule
        removeUnusedUserAvatar(previous)
    }

    private func removeUnusedUserAvatar(_ previous: String?) {
        let directory = store.userDisplayImageDirectory
        if let previous, !store.userDisplayRules.values.contains(where: { $0.avatarFile == previous }) {
            do {
                try FileManager.default.removeItem(at: directory.appending(fileName: SafeFileName(previous)))
            } catch {
                SciaLog.logger(category: "userDisplay").error("unused image cleanup failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }
}
