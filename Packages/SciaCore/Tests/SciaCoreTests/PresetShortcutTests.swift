import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// ショートカットから、アプリのプリセットを切り替え、アカウントにプリセットを割り当てる（docs/preset.md）。
@Suite(.scratch)
@MainActor
struct PresetShortcutTests {
    private func makeStore() throws -> (SettingsStore, home: PresetID) {
        let store = SettingsStore(defaults: TestScratch.defaults("PresetShortcutTests"))
        var home: PresetID = .builtIn(.standard)
        try store.tryUpdateLibrary { library throws(PresetError) in
            home = try library.create(parent: .builtIn(.standard), name: "家")
        }
        return (store, home)
    }

    @Test func selectsAppPreset() throws {
        let (store, home) = try makeStore()
        try store.applyShortcut(selecting: home, for: .app, signedInAccounts: [])
        #expect(store.library.appPreset == home)
    }

    /// アカウントに割り当て、プリセットを渡さなければ割り当てを外す。
    @Test func assignsAndUnassignsAccount() throws {
        let (store, home) = try makeStore()
        try store.applyShortcut(selecting: home, for: .account("a@example.social"), signedInAccounts: ["a@example.social"])
        #expect(store.library.accountPresets["a@example.social"] == home)

        try store.applyShortcut(selecting: nil, for: .account("a@example.social"), signedInAccounts: ["a@example.social"])
        #expect(store.library.accountPresets.isEmpty)
    }

    /// 消したプリセットを指したら、何も変えずに失敗する。
    @Test func deletedPresetFails() throws {
        let (store, home) = try makeStore()
        try store.tryUpdateLibrary { library throws(PresetError) in try library.delete(home) }
        let before = store.library

        #expect(throws: PresetError.presetNotFound) { try store.applyShortcut(selecting: home, for: .app, signedInAccounts: []) }
        #expect(store.library == before)
    }

    /// ログアウトしたアカウントを指したら、割り当ても外すことも、何も変えずに失敗する。ログアウトで消した割り当てを作り直さないため。
    @Test func loggedOutAccountFails() throws {
        let (store, home) = try makeStore()
        let before = store.library

        #expect(throws: PresetError.accountNotFound) {
            try store.applyShortcut(selecting: home, for: .account("gone@example.social"), signedInAccounts: ["a@example.social"])
        }
        #expect(throws: PresetError.accountNotFound) {
            try store.applyShortcut(selecting: nil, for: .account("gone@example.social"), signedInAccounts: ["a@example.social"])
        }
        #expect(store.library == before)
    }

    /// ショートカットに残すプリセットの指し方は、文字列にして読み戻せる。
    @Test func tokenRoundTrips() {
        for id in [PresetID.builtIn(.standard), .user(3)] {
            #expect(PresetID(token: id.token) == id)
        }
        #expect(PresetID(token: "user:x") == nil)
        #expect(PresetID(token: "builtIn:unknown") == nil)
    }
}
