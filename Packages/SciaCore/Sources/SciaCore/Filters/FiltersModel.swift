import Foundation
public import Observation
import os

/// 自分のフィルターのリストと、作る、変える、消す操作。決まりはdocs/filters.mdの「作る、変える、消す」にある。
@MainActor
@Observable
public final class FiltersModel {
    /// 読んだフィルター。名前の順に並べる。まだ読めていなければnil。
    public private(set) var filters: [ServerFilter]?
    /// 最初の読み込みに失敗した理由。読めたらnil。
    public private(set) var loadFailure: ErrorPresentation?
    /// 保存を送っている途中か。
    public private(set) var isSaving = false

    /// 作る、変える、消すをサーバーが受け付けたときに呼ぶ。
    @ObservationIgnored public var onChange: () -> Void = {}
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// 作る、変える、消すを受け付けた回数。読んでいる間に受け付けたら、その前の応答で古いリストに戻さない。
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private let api: API
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let logger = SciaLog.logger(category: "filters")
    public var runningTaskCount: Int { tasks.runningCount }

    /// サーバーとのやり取り。部品カタログが、通信せずに状態を並べるために差し替える。
    public struct API: Sendable {
        public var load: @Sendable () async throws -> [ServerFilter]
        public var save: @Sendable (FilterDraft) async throws -> ServerFilter
        public var delete: @Sendable (String) async throws -> Void

        public init(load: @escaping @Sendable () async throws -> [ServerFilter], save: @escaping @Sendable (FilterDraft) async throws -> ServerFilter, delete: @escaping @Sendable (String) async throws -> Void) {
            self.load = load
            self.save = save
            self.delete = delete
        }

        public init(client: MastodonClient) {
            self.init(load: { try await client.filters() }, save: { try await Self.send($0, client: client) }, delete: { try await client.deleteFilter($0) })
        }

        private static func send(_ draft: FilterDraft, client: MastodonClient) async throws -> ServerFilter {
            guard let original = draft.original else {
                let expiresIn: Duration? = if case .after(let duration) = draft.expiry { duration } else { nil }
                return try await client.createFilter(title: draft.trimmedTitle, context: draft.orderedContexts, action: draft.action, expiresIn: expiresIn, keywords: draft.newKeywords)
            }
            return try await client.updateFilter(original.id, title: draft.trimmedTitle, context: draft.orderedContexts, action: draft.action, expiry: draft.expiry, keywords: draft.keywordChanges)
        }
    }

    public init(api: API, tasks: TaskScope) {
        self.api = api
        self.tasks = tasks
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    @discardableResult
    public func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        if let loading { return loading }
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer { loading = nil }
            do {
                let changesBefore = changeCount
                let loaded = try await api.load()
                guard !tasks.isClosed, changeCount == changesBefore else { return }
                filters = Self.sorted(loaded)
                loadFailure = nil
                logger.info("filters load done count=\(loaded.count, privacy: .public)")
            } catch {
                guard let presentation = handle(error, during: "load") else { return }
                // 読めたリストは消さず、まだ何も読めていなければ理由を出す。
                if filters == nil {
                    loadFailure = presentation
                }
            }
        }
        return loading
    }

    /// 下書きを保存する。作ったフィルターも変えたフィルターも、名前の順の位置に入れる。
    /// - Parameter completion: 保存できたらnil、できなかったら理由で呼ぶ。止めたあとや取り消しでは呼ばない。
    @discardableResult
    public func save(_ draft: FilterDraft, completion: @escaping @MainActor (ErrorPresentation?) -> Void) -> Task<Void, Never>? {
        guard draft.canSave, !isSaving else { return nil }
        logger.info("filters save new=\(draft.original == nil, privacy: .public)")
        let task = tasks.run(.action) { [weak self] in
            guard let self else { return }
            defer { isSaving = false }
            do {
                let saved = try await api.save(draft)
                guard !tasks.isClosed else { return }
                changeCount += 1
                filters = Self.sorted((filters ?? []).filter { $0.id != saved.id } + [saved])
                onChange()
                completion(nil)
            } catch {
                guard let presentation = handle(error, during: "save") else { return }
                completion(presentation)
            }
        }
        isSaving = task != nil
        return task
    }

    /// フィルターを消す。サーバーが受け付けたら、リストから外す。保存を送っている間は消さない。
    /// - Parameter completion: 消せたらnil、消せなかったら理由で呼ぶ。止めたあとや取り消しでは呼ばない。
    @discardableResult
    public func delete(_ id: String, completion: @escaping @MainActor (ErrorPresentation?) -> Void) -> Task<Void, Never>? {
        // 保存の応答が削除のあとに届くと、消したフィルターをリストに戻してしまう。
        guard !isSaving else { return nil }
        logger.info("filters delete")
        // 送り終える前に押し直しても、同じ要求を重ねて送らない。
        return tasks.run(key: "delete:\(id)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                try await api.delete(id)
                guard !tasks.isClosed else { return }
                changeCount += 1
                filters?.removeAll { $0.id == id }
                onChange()
                completion(nil)
            } catch {
                guard let presentation = handle(error, during: "delete") else { return }
                completion(presentation)
            }
        }
    }

    /// 名前の順に並べる。APIは順を決めずに返し、Mastodonのwebの設定は名前の順に並べているため。同じ名前はIDの順にする。
    private static func sorted(_ filters: [ServerFilter]) -> [ServerFilter] {
        filters.sorted { first, second in
            switch first.title.localizedStandardCompare(second.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.id.localizedStandardCompare(second.id) == .orderedAscending
            }
        }
    }

    /// 失敗をログに残して、知らせる中身を返す。止めたあとや取り消しならnil。
    private func handle(_ error: any Error, during operation: String) -> ErrorPresentation? {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return nil }
        logger.error("filters \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        return ErrorPresentation(error)
    }
}
