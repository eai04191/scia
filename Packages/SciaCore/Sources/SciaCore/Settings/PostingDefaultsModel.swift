import Foundation
public import Observation
import os

/// アカウントの画面の「投稿のデフォルト」。新しく投稿するときの既定を読み、選んだ値をすぐ保存する。決まりはdocs/account-screen.mdの「投稿のデフォルト」にある。
@MainActor
@Observable
public final class PostingDefaultsModel {
    /// 読み込みと保存の送り先。
    public struct API: Sendable {
        /// 今の既定を読み直す。
        public var load: @MainActor @Sendable () async throws -> ServerPreferences
        /// 既定を1つ変え、変えたあとの既定を返す。
        public var save: @MainActor @Sendable (PostingDefaultChange) async throws -> ServerPreferences?

        public init(
            load: @escaping @MainActor @Sendable () async throws -> ServerPreferences,
            save: @escaping @MainActor @Sendable (PostingDefaultChange) async throws -> ServerPreferences?
        ) {
            self.load = load
            self.save = save
        }

        public init(session: AccountSession) {
            self.init(
                load: { [weak session] in
                    guard let session else { throw CancellationError() }
                    return try await session.reloadPreferences()
                },
                save: { [weak session] change in try await session?.updatePostingDefault(change) }
            )
        }
    }

    /// 画面に出す既定。選んだ値は、保存を終える前から入れる。まだ読めていなければnil。
    public var preferences: ServerPreferences? {
        confirmed.map { pending.reduce($0) { $1.applied(to: $0) } }
    }
    /// 最初の読み込みに失敗した理由。読めたらnil。
    public private(set) var loadFailure: ErrorPresentation?
    /// 保存できなかったときに呼ぶ。知らせ方は作る側が決める。
    @ObservationIgnored public var onFailure: (ErrorPresentation) -> Void = { _ in }

    /// サーバーが返した最後の既定。保存できなかった項目は、この値に戻る。
    private var confirmed: ServerPreferences?
    /// 保存を終えていない変更。選んだ順に送る。
    private var pending: [PostingDefaultChange] = []
    /// 選んだ回数。選ぶ前に始めた読み込みを、あとから届いたときに見分ける。
    @ObservationIgnored private var selections = 0
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let api: API
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let logger = SciaLog.logger(category: "postingDefaults")
    public var runningTaskCount: Int { tasks.runningCount }

    /// - Parameter initial: すでに読めている既定。読み直すまでの表示に使う。
    public init(api: API, initial: ServerPreferences? = nil, tasks: TaskScope) {
        self.api = api
        confirmed = initial
        self.tasks = tasks
    }

    /// 引用できる人を選べない理由。選べるときはnil。既定の公開範囲がフォロワーのみの間は、サーバーがいつも「自分のみ」にする。
    public var quotePolicyFixedReason: String? {
        preferences.flatMap { QuotePolicy.fixedReason(for: $0.defaultVisibility) }
    }

    /// 画面に出す、引用できる人の既定。引用に対応していないサーバーではnilで、項目を出さない。
    public var shownQuotePolicy: QuotePolicy? {
        preferences.flatMap { $0.defaultQuotePolicy?.effective(for: $0.defaultVisibility) }
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    @discardableResult
    public func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        if let loading { return loading }
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer { loading = nil }
            do {
                let selectionsBefore = selections
                let loaded = try await api.load()
                guard !tasks.isClosed else { return }
                // 読んでいる間に選んでいたら、読んだのは保存の前の値なので、上書きしない。保存の応答が新しい値を入れる。
                if selections == selectionsBefore { confirmed = loaded }
                loadFailure = nil
            } catch {
                guard let presentation = handle(error, during: "load") else { return }
                // 読めた既定は消さず、まだ何も読めていなければ理由を出す。
                if confirmed == nil { loadFailure = presentation }
            }
        }
        return loading
    }

    /// 既定を1つ選び、すぐ保存する。保存できなければ元の値に戻し、`onFailure`を呼ぶ。同じ値なら送らない。
    public func select(_ change: PostingDefaultChange) {
        guard let preferences, change.applied(to: preferences) != preferences else { return }
        pending.append(change)
        selections += 1
        let previous = sending
        sending = tasks.run(.action) { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let saved = try await api.save(change)
                if let saved { confirmed = saved }
                logger.info("postingDefaults saved")
            } catch {
                if let presentation = handle(error, during: "save") { onFailure(presentation) }
            }
            // 選んだ順に送っているので、終えたのは先頭の変更。
            if !pending.isEmpty { pending.removeFirst() }
        }
    }

    private func handle(_ error: any Error, during operation: String) -> ErrorPresentation? {
        guard !tasks.isClosed, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return nil }
        logger.error("postingDefaults \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        return ErrorPresentation(error)
    }
}
