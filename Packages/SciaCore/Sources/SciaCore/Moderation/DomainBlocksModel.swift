import Foundation
public import Observation
import os

/// 自分がブロックしたドメインのリストと、足す、解除する操作。決まりはdocs/moderation-lists.mdの「ブロックしたドメイン」にある。
@MainActor
@Observable
public final class DomainBlocksModel {
    /// サーバーが返す順（新しくブロックした順）。まだ読めていなければnil。
    public private(set) var domains: [String]?
    /// 最初の読み込みに失敗した理由。読めたらnil。
    public private(set) var loadFailure: ErrorPresentation?
    /// 続きのページを読めなかった理由。再読み込みするか、続きを読めたらnil。
    public private(set) var loadMoreFailure: ErrorPresentation?
    /// これより後ろはない。
    public private(set) var reachedEnd = false
    public private(set) var isLoadingMore = false

    /// 足すか解除するのをサーバーが受け付けたときに、そのドメインで呼ぶ。
    @ObservationIgnored public var onChange: (String) -> Void = { _ in }
    @ObservationIgnored private var nextMaxID: String?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// 足したか解除した回数。読んでいる間に受け付けたら、その前に送った読み込みの応答で古いリストに戻さない。
    @ObservationIgnored private var changeCount = 0
    /// 読んでいる間に解除したドメイン。続きのページが前のページと重なって返ったときに、解除したドメインを戻さない。
    @ObservationIgnored private var unblockedDuringLoad: Set<String> = []
    /// 読んでいる間にほかの入口で変わったので、読み終えたら再読み込みする。
    @ObservationIgnored private var reloadsAfterLoad = false
    @ObservationIgnored private let api: API
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let logger = SciaLog.logger(category: "domainBlocks")
    public var runningTaskCount: Int { tasks.runningCount }

    /// サーバーとのやり取り。テストと部品カタログが、通信せずに状態を作るために差し替える。
    public struct API: Sendable {
        public var load: @Sendable (_ maxID: String?) async throws -> DomainBlockPage
        public var block: @Sendable (String) async throws -> Void
        public var unblock: @Sendable (String) async throws -> Void

        public init(
            load: @escaping @Sendable (_ maxID: String?) async throws -> DomainBlockPage,
            block: @escaping @Sendable (String) async throws -> Void,
            unblock: @escaping @Sendable (String) async throws -> Void
        ) {
            self.load = load
            self.block = block
            self.unblock = unblock
        }

        /// 1回に読む件数。APIの既定と同じ。
        static let pageSize = 100

        public init(client: MastodonClient) {
            self.init(
                load: { try await client.domainBlocks(maxID: $0, limit: Self.pageSize) },
                block: { try await client.blockDomain($0) },
                unblock: { try await client.unblockDomain($0) }
            )
        }
    }

    public init(api: API, tasks: TaskScope) {
        self.api = api
        self.tasks = tasks
    }

    /// 最初のページから再読み込みする。読んでいる途中なら、その読み込みに任せる。読めなければ、読めたリストを残す。
    @discardableResult
    public func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        if let loading { return loading }
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer { finishLoading() }
            do {
                let changesBefore = changeCount
                let page = try await api.load(nil)
                guard !tasks.isClosed, changeCount == changesBefore else { return }
                domains = Self.unique(page.domains)
                apply(next: page, after: nil)
                loadFailure = nil
                loadMoreFailure = nil
                logger.info("domainBlocks load done count=\(page.domains.count, privacy: .public)")
            } catch {
                guard let presentation = handle(error, during: "load") else { return }
                if domains == nil {
                    loadFailure = presentation
                }
            }
        }
        return loading
    }

    /// 続きのページを読む。読んでいる途中か、終わりに着いていれば何もしない。
    @discardableResult
    public func loadMore(purpose: RequestPurpose) -> Task<Void, Never>? {
        guard loading == nil, !reachedEnd, let maxID = nextMaxID, domains != nil else { return nil }
        isLoadingMore = true
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer {
                isLoadingMore = false
                finishLoading()
            }
            do {
                let page = try await api.load(maxID)
                guard !tasks.isClosed else { return }
                domains = Self.unique((domains ?? []) + page.domains.filter { !unblockedDuringLoad.contains($0) })
                apply(next: page, after: maxID)
                loadMoreFailure = nil
                logger.info("domainBlocks loadMore done count=\(page.domains.count, privacy: .public)")
            } catch {
                guard let presentation = handle(error, during: "loadMore") else { return }
                loadMoreFailure = presentation
            }
        }
        return loading
    }

    /// 入れた文字をドメインの形に直して送る。受け付けたら、リストの先頭に足す。もう並んでいれば動かさない。
    /// - Parameter completion: ブロックできたらnil、できなかったら理由で呼ぶ。止めたあとや取り消しでは呼ばない。
    @discardableResult
    public func block(_ input: String, completion: @escaping @MainActor (ErrorPresentation?) -> Void) -> Task<Void, Never>? {
        let domain = DomainInput.normalize(input)
        guard !domain.isEmpty else { return nil }
        logger.info("domainBlocks block")
        return tasks.run(key: "domain:\(domain)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                try await api.block(domain)
                guard !tasks.isClosed else { return }
                changeCount += 1
                if domains?.contains(domain) == false {
                    domains?.insert(domain, at: 0)
                }
                onChange(domain)
                completion(nil)
            } catch {
                guard let presentation = handle(error, during: "block") else { return }
                completion(presentation)
            }
        }
    }

    /// ブロックを解除する。受け付けたら、リストから外す。
    /// - Parameter completion: 解除できたらnil、できなかったら理由で呼ぶ。止めたあとや取り消しでは呼ばない。
    @discardableResult
    public func unblock(_ domain: String, completion: @escaping @MainActor (ErrorPresentation?) -> Void) -> Task<Void, Never>? {
        logger.info("domainBlocks unblock")
        return tasks.run(key: "domain:\(domain)", .skippingWhileRunning, .action) { [weak self] in
            guard let self else { return }
            do {
                try await api.unblock(domain)
                guard !tasks.isClosed else { return }
                changeCount += 1
                if loading != nil {
                    unblockedDuringLoad.insert(domain)
                }
                domains?.removeAll { $0 == domain }
                onChange(domain)
                completion(nil)
            } catch {
                guard let presentation = handle(error, during: "unblock") else { return }
                completion(presentation)
            }
        }
    }

    /// ほかの入口（ユーザーのメニュー）でドメインのブロックが変わった。まだ読み始めていなければ、開いたときに読むので何もしない。
    /// 読んでいる途中なら、初めて読んでいるときも、その応答は変わる前のものなので捨て、読み終えてから再読み込みする。
    public func didChangeOutside() {
        guard domains != nil || loading != nil else { return }
        changeCount += 1
        if loading != nil {
            reloadsAfterLoad = true
        } else {
            reload(purpose: .display)
        }
    }

    private func finishLoading() {
        loading = nil
        unblockedDuringLoad = []
        guard reloadsAfterLoad, !tasks.isClosed else { return }
        reloadsAfterLoad = false
        reload(purpose: .display)
    }

    /// 同じ位置を返し続けるサーバーで同じページを読み続けないよう、続きの位置が進まなければ終わりにする。
    private func apply(next page: DomainBlockPage, after maxID: String?) {
        nextMaxID = page.nextMaxID
        reachedEnd = page.nextMaxID == nil || page.nextMaxID == maxID || page.domains.isEmpty
    }

    private static func unique(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.filter { seen.insert($0).inserted }
    }

    /// 失敗をログに残して、知らせる中身を返す。止めたあとや取り消しならnil。
    private func handle(_ error: any Error, during operation: String) -> ErrorPresentation? {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return nil }
        logger.error("domainBlocks \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        return ErrorPresentation(error)
    }
}
