public import Observation

/// 自分のプロフィールの編集画面の状態。元の値を読み、編集を受け、保存する。
@MainActor
@Observable
public final class ProfileEditor {
    /// 通信の口。テストとカタログでは差し替える。
    public struct API: Sendable {
        public var source: @Sendable () async throws -> ProfileSource
        public var save: @Sendable (ProfileDraft) async throws -> ProfileSource

        public init(source: @escaping @Sendable () async throws -> ProfileSource, save: @escaping @Sendable (ProfileDraft) async throws -> ProfileSource) {
            self.source = source
            self.save = save
        }
    }

    /// 元の値の読み込み。
    public enum Source {
        case loading
        case loaded(ProfileSource)
        case failed(any Error)
    }

    public private(set) var source: Source = .loading
    /// 読み込むまでは空のまま。読み込んだら、元の値から始める。
    public var draft: ProfileDraft?
    public private(set) var isSaving = false
    /// 上限。サーバーの設定を読めなければ、4.6.0より前のMastodonの値のまま使う。超えた分はサーバーが422で拒む。
    public var limits: ProfileLimits
    public var charactersReservedPerURL: Int
    private let api: API

    public init(limits: ProfileLimits = .beforeMastodon46, charactersReservedPerURL: Int = 23, api: API) {
        self.limits = limits
        self.charactersReservedPerURL = charactersReservedPerURL
        self.api = api
    }

    /// 元の値を読む。読み込み中なら何もしない。読み直したときも、書きかけの下書きは残す。
    public func load() async {
        if case .loaded = source, draft != nil { return }
        source = .loading
        do {
            let loaded = try await api.source()
            source = .loaded(loaded)
            if draft == nil {
                draft = ProfileDraft(source: loaded)
            }
        } catch {
            source = .failed(error)
        }
    }

    public var hasChanges: Bool {
        guard case .loaded(let loaded) = source, let draft else { return false }
        return draft.hasChanges(from: loaded)
    }

    public var problems: [ProfileDraftProblem] {
        draft?.problems(limits: limits, charactersReservedPerURL: charactersReservedPerURL) ?? []
    }

    public var canSave: Bool {
        hasChanges && problems.isEmpty && !isSaving
    }

    /// 保存し、保存したあとのプロフィールを返す。失敗したら下書きを残したまま投げる。
    public func save() async throws -> ProfileSource {
        guard let draft, !isSaving else { throw CancellationError() }
        isSaving = true
        defer { isSaving = false }
        let saved = try await api.save(draft)
        source = .loaded(saved)
        self.draft = ProfileDraft(source: saved)
        return saved
    }
}
