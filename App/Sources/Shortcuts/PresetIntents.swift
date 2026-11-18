import AppIntents
import SciaCore

// App Intentsの名前は、ビルドの時点で中身を読むので、文字列リテラルでここに書く。SciaCoreの値を渡すと、ショートカットのアプリに名前が出ない。
// そのため、名前の行だけ`user_text_outside_core`から外す。実行の中の文言は、SciaCoreから読む。

/// ショートカットで指すプリセット。
struct PresetEntity: AppEntity {
    // scialint:disable:next user_text_outside_core
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "プリセット"
    static let defaultQuery = PresetQuery()

    /// `PresetID.token`。
    let id: String
    let name: String

    /// 組み込みのプリセットには鍵のアイコンを添える。名前は使う人のプリセットと重なりうるので、アイコンで見分ける（docs/preset.md）。
    var displayRepresentation: DisplayRepresentation {
        guard PresetID(token: id).map({ if case .builtIn = $0 { true } else { false } }) == true else {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: "lock.fill"))
    }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        await MainActor.run {
            let all = Self.all()
            return identifiers.compactMap { id in all.first { $0.id == id } }
        }
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        await MainActor.run { Self.all() }
    }

    /// 組み込みのプリセット、使う人のプリセットの順。
    @MainActor
    private static func all() -> [PresetEntity] {
        let library = AppDependencies.settings.store.library
        let ids = BuiltInPreset.allCases.map(PresetID.builtIn) + library.userPresets.map { PresetID.user($0.id) }
        return ids.compactMap { id in
            library.name(of: id).map { PresetEntity(id: id.token, name: $0) }
        }
    }
}

/// ショートカットで指すアカウント。
struct AccountEntity: AppEntity {
    // scialint:disable:next user_text_outside_core
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "アカウント"
    static let defaultQuery = AccountQuery()

    /// `Credential.handle`。
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        try await MainActor.run {
            let handles = try Self.signedIn()
            return identifiers.filter(handles.contains).map(AccountEntity.init)
        }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        try await MainActor.run { try Self.signedIn().map(AccountEntity.init) }
    }

    /// ログインしているアカウントのハンドル。アカウントの切り替えのメニューと同じ順。
    /// アカウントの一覧を読めないとき（Keychainを読めないなど）は、ログインしていないことにせず、読めなかったことを返す。
    @MainActor
    static func signedIn() throws -> [String] {
        try AppDependencies.accounts.get().accounts.map(\.handle)
    }
}

/// アプリのプリセットを切り替える。アプリを前に出さずに切り替え、次に表示するときに効かせる（docs/preset.md）。
struct SelectAppPresetIntent: AppIntent {
    // scialint:disable:next user_text_outside_core
    static let title: LocalizedStringResource = "アプリのプリセットを設定"
    static let openAppWhenRun = false

    // scialint:disable:next user_text_outside_core
    @Parameter(title: "プリセット")
    var preset: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try PresetShortcut.apply(token: preset.id, for: .app)
        return .result()
    }
}

/// アカウントにプリセットを割り当てる。プリセットを選ばなければ、割り当てを外してアプリのプリセットに従わせる。
struct AssignAccountPresetIntent: AppIntent {
    // scialint:disable:next user_text_outside_core
    static let title: LocalizedStringResource = "アカウントのプリセットを設定"
    static let openAppWhenRun = false

    // scialint:disable:next user_text_outside_core
    @Parameter(title: "アカウント")
    var account: AccountEntity

    // scialint:disable:next user_text_outside_core
    @Parameter(title: "プリセット")
    var preset: PresetEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        try PresetShortcut.apply(token: preset?.id, for: .account(account.id))
        return .result()
    }
}

private enum PresetShortcut {
    @MainActor
    static func apply(token: String?, for scope: PresetScope) throws {
        var id: PresetID?
        if let token {
            guard let parsed = PresetID(token: token) else { throw ShortcutFailure(.presetNotFound) }
            id = parsed
        }
        // アプリのプリセットを切り替えるときはアカウントを指さないので、アカウントの一覧を読まない。
        let signedIn: [String] = if case .account = scope { try AccountQuery.signedIn() } else { [] }
        do {
            try AppDependencies.settings.store.applyShortcut(selecting: id, for: scope, signedInAccounts: signedIn)
        } catch {
            throw ShortcutFailure(error)
        }
    }
}

/// ショートカットのアプリに出す、失敗の理由。
private struct ShortcutFailure: Error, CustomLocalizedStringResourceConvertible {
    let reason: PresetError

    init(_ reason: PresetError) {
        self.reason = reason
    }

    var localizedStringResource: LocalizedStringResource {
        let text = switch reason {
        case .accountNotFound: PresetTexts.accountNotFound
        case .presetNotFound: PresetTexts.presetNotFound
        case .builtInIsReadOnly, .invalidValue, .nameTaken: preconditionFailure("プリセットを選ぶ操作は、値も名前も変えないので起きない")
        }
        return LocalizedStringResource(String.LocalizationValue(text))
    }
}
