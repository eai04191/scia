import Foundation
import os

@MainActor
public final class UserDisplayLoader {
    private let settings: AppSettings
    private let tasks: TaskScope
    private let loadAccount: @MainActor (String) async throws -> Account
    private var displays: [String: UserDisplay] = [:]
    private var loads: [String: Task<Void, Never>] = [:]

    public init(settings: AppSettings, tasks: TaskScope, loadAccount: @escaping @MainActor (String) async throws -> Account) {
        self.settings = settings
        self.tasks = tasks
        self.loadAccount = loadAccount
    }

    public func display(for handle: String) -> UserDisplay {
        if let display = displays[handle] { return display }
        let display = settings.userDisplays.display(for: handle, in: settings)
        displays[handle] = display
        return display
    }

    public func load(_ handle: String) {
        let display = display(for: handle)
        guard settings.userDisplays.rules[handle] != nil, display.customAvatar == nil else {
            cancel(handle)
            return
        }
        guard !display.hasAccount, loads[handle] == nil else { return }
        loads[handle] = tasks.run(.display) { [weak self, loadAccount, settings] in
            do {
                let account = try await loadAccount(handle)
                guard !Task.isCancelled else { return }
                settings.userDisplays.receive(account, in: settings)
            } catch {
                guard !Task.isCancelled else { return }
                SciaLog.logger(category: "userDisplay").error("list avatar account load failed: \(SciaLog.describe(error), privacy: .public)")
            }
            self?.loads[handle] = nil
        }
    }

    public func cancel(_ handle: String) {
        loads.removeValue(forKey: handle)?.cancel()
    }
}
