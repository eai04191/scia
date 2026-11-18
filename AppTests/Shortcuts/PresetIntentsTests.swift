import SciaCore
import SciaTesting
import Testing
@testable import Scia

/// ショートカットのアクションが、アプリの設定のプリセットを切り替える（docs/preset.md）。
@Suite(.failureState)
@MainActor
struct PresetIntentsTests {
    @Test func selectsAppPreset() async throws {
        let store = AppDependencies.settings.store
        let original = store.library.appPreset
        defer { try? store.applyShortcut(selecting: original, for: .app, signedInAccounts: []) }
        var created: PresetID = .builtIn(.standard)
        try store.tryUpdateLibrary { library throws(PresetError) in
            created = try library.create(parent: .builtIn(.standard), name: "ショートカットのテスト")
        }
        let intent = SelectAppPresetIntent()
        intent.preset = PresetEntity(id: created.token, name: "ショートカットのテスト")

        _ = try await intent.perform()

        #expect(store.library.appPreset == created)
    }

    /// 消したプリセットを指したら、何も変えずに失敗する。
    @Test func deletedPresetFails() async throws {
        let store = AppDependencies.settings.store
        var created: PresetID = .builtIn(.standard)
        try store.tryUpdateLibrary { library throws(PresetError) in
            created = try library.create(parent: .builtIn(.standard), name: "消すプリセット")
        }
        try store.tryUpdateLibrary { library throws(PresetError) in try library.delete(created) }
        let before = store.library
        let intent = SelectAppPresetIntent()
        intent.preset = PresetEntity(id: created.token, name: "消すプリセット")

        await #expect(throws: (any Error).self) { try await intent.perform() }
        #expect(store.library == before)
    }
}
