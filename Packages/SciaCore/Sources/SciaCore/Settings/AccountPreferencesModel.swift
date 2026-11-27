public import Observation

/// アカウントの画面の「外観」。Sciaが従うのにAPIでは変えられないアカウント設定を読む。決まりはdocs/account-screen.mdの「外観」にある。
@MainActor
@Observable
public final class AccountPreferencesModel {
    /// 読めたアカウント設定。まだ読めていなければnil。
    public private(set) var preferences: ServerPreferences?
    /// 最後の読み込みに失敗した。
    public private(set) var loadFailed = false

    @ObservationIgnored private let load: @MainActor @Sendable () async throws -> ServerPreferences
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private var loading: Task<Void, Never>?
    public var runningTaskCount: Int { tasks.runningCount }

    /// - Parameters:
    ///   - initial: すでに読めているアカウント設定。再読み込みするまでの表示に使う。
    ///   - tasks: セッションの持ち主の子。閉じたセッションで読んだ値を保持させないため。
    public init(initial: ServerPreferences?, load: @escaping @MainActor @Sendable () async throws -> ServerPreferences, tasks: TaskScope) {
        preferences = initial
        self.load = load
        self.tasks = tasks
    }

    /// 再読み込みする。読んでいる途中なら、それを止めてから読む。ウェブで設定を変えて戻ったときに、変える前に始めた読み込みの応答で上書きしないため。
    /// 読めなければ、前に読めた値はそのまま出す。
    public func reload(purpose: RequestPurpose) {
        loading?.cancel()
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await load()
                guard !Task.isCancelled, !tasks.isClosed else { return }
                preferences = loaded
                loadFailed = false
            } catch {
                guard !Task.isCancelled, !tasks.isClosed else { return }
                loadFailed = true
            }
        }
    }
}
