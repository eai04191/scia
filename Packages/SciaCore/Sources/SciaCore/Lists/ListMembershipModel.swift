import Foundation
public import Observation
import os

/// ユーザーのメニューの「リストに追加」のシートで、その人をどのリストに入れるか。決まりはdocs/lists.mdの「リストに追加」にある。
/// 押したらすぐチェックマークを変え、送れなければ元に戻す。リストごとに送る順を守り、あとから押した方を先に届けない。
@MainActor
@Observable
public final class ListMembershipModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(ErrorPresentation)
    }

    /// その人をリストに足せるか。
    public enum Availability: Equatable, Sendable {
        /// 自分か、フォロー中かフォローをリクエスト中。
        case available
        /// フォローもリクエストもしていない。フォローしてから足す。
        case needsFollow
        /// ブロックしているか、されている。フォローできないので足せない。
        case blocked
    }

    /// リストを押したときに起きること。
    public enum ToggleResult: Equatable, Sendable {
        /// 足すか外すのを送り始めた。
        case sent
        /// フォローが要る。確かめてから`followAndAdd`を呼ぶ。
        case needsFollow
        /// 足せない相手か、まだ読み込んでいない。
        case unavailable
    }

    /// 通信。セッションが作る。
    public struct API: Sendable {
        /// 自分のリスト。
        public let lists: @Sendable () async throws -> [MastodonList]
        /// その人が入っているリスト。
        public let listsContaining: @Sendable () async throws -> [MastodonList]
        /// その人との関係。
        public let relationship: @Sendable () async throws -> Relationship
        public let add: @Sendable (_ listID: String) async throws -> Void
        public let remove: @Sendable (_ listID: String) async throws -> Void
        /// その人をフォローし、新しい関係を返す。
        public let follow: @Sendable () async throws -> Relationship
        public let create: @Sendable (_ title: String) async throws -> MastodonList

        public init(
            lists: @escaping @Sendable () async throws -> [MastodonList],
            listsContaining: @escaping @Sendable () async throws -> [MastodonList],
            relationship: @escaping @Sendable () async throws -> Relationship,
            add: @escaping @Sendable (_ listID: String) async throws -> Void,
            remove: @escaping @Sendable (_ listID: String) async throws -> Void,
            follow: @escaping @Sendable () async throws -> Relationship,
            create: @escaping @Sendable (_ title: String) async throws -> MastodonList
        ) {
            self.lists = lists
            self.listsContaining = listsContaining
            self.relationship = relationship
            self.add = add
            self.remove = remove
            self.follow = follow
            self.create = create
        }
    }

    public private(set) var phase: Phase = .loading
    /// 自分のリスト。サーバーが返す順。
    public private(set) var lists: [MastodonList] = []
    /// 画面に出す、その人が入っているリスト。押した結果は、送り終える前から入れる。
    public private(set) var memberListIDs: Set<String> = []
    /// その人との関係。自分なら読まないのでnil。
    public private(set) var relationship: Relationship?
    /// フォローしている途中。
    public private(set) var isFollowing = false
    /// 相手が自分か。Mastodonは自分をリストに入れられ、フォローは要らない。
    public let isMyself: Bool

    public var availability: Availability {
        if isMyself { return .available }
        guard let relationship else { return .needsFollow }
        if relationship.blocking || relationship.blockedBy { return .blocked }
        return relationship.following || relationship.requested ? .available : .needsFollow
    }

    /// 失敗した操作。
    public enum Operation: Sendable {
        case add
        case remove
        case follow

        /// 失敗を知らせる文言。
        public var failureTitle: String {
            switch self {
            case .add: "リストに追加できませんでした"
            case .remove: "リストから外せませんでした"
            case .follow: "フォローできませんでした"
            }
        }
    }

    /// 足す、外す、フォローに失敗したときに呼ぶ。知らせ方は作る側が決める。
    @ObservationIgnored public var onFailure: (Operation, ErrorPresentation) -> Void = { _, _ in }
    /// フォローできたときに呼ぶ。セッションが覚えている関係を新しくする。
    @ObservationIgnored public var onFollowed: (Relationship) -> Void = { _ in }
    /// サーバーが受け付けた、その人が入っているリスト。送れなかったリストは、この値に戻す。
    @ObservationIgnored private var confirmedListIDs: Set<String> = []
    /// リストごとに、最後に押した回の番号。送り終えたときに、その後に押し直していれば、戻さない。
    @ObservationIgnored private var selections: [String: Int] = [:]
    @ObservationIgnored private var nextSelection = 0
    /// リストごとの、送っている途中の操作。順に送る。
    @ObservationIgnored private var sending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let api: API
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private let logger = SciaLog.logger(category: "listMembership")
    public var runningTaskCount: Int { tasks.runningCount }

    public init(isMyself: Bool, api: API, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.isMyself = isMyself
        self.api = api
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    /// リストと、その人が入っているリストと、関係を読む。どれかが読めなければ、読めなかったことを出す。
    @discardableResult
    public func load() -> Task<Void, Never>? {
        phase = .loading
        let api = api
        let isMyself = isMyself
        return tasks.run(.action) { [weak self] in
            do {
                async let lists = api.lists()
                async let containing = api.listsContaining()
                async let relationship: Relationship? = isMyself ? nil : api.relationship()
                let loaded = try await (lists, containing, relationship)
                guard let self, !tasks.isClosed else { return }
                self.lists = loaded.0
                confirmedListIDs = Set(loaded.1.map(\.id))
                memberListIDs = confirmedListIDs
                self.relationship = loaded.2
                phase = .loaded
                logger.info("listMembership load done lists=\(loaded.0.count, privacy: .public) member=\(loaded.1.count, privacy: .public)")
            } catch {
                guard let presentation = self?.handle(error, during: "load") else { return }
                self?.phase = .failed(presentation)
            }
        }
    }

    /// リストを押した。入っていれば外し、入っていなければ足す。フォローが要るときは送らずに知らせる。
    public func toggle(_ listID: String) -> ToggleResult {
        guard phase == .loaded, !isFollowing else { return .unavailable }
        let isMember = memberListIDs.contains(listID)
        if !isMember {
            switch availability {
            case .available: break
            case .needsFollow: return .needsFollow
            case .blocked: return .unavailable
            }
        }
        send(isMember ? .remove : .add, listID: listID)
        return .sent
    }

    /// フォローしてから足す。承認制の相手はリクエスト中になり、そのまま足せる。フォローできなければ足さない。
    @discardableResult
    public func followAndAdd(_ listID: String) -> Task<Void, Never>? {
        guard phase == .loaded, !isFollowing, availability == .needsFollow else { return nil }
        isFollowing = true
        let api = api
        // シートを閉じても、フォローしてから足すところまで送るよう、送り終えるまでモデルを手放さない。
        return tasks.run(.action) { [self] in
            do {
                let relationship = try await api.follow()
                guard !tasks.isClosed else { return }
                isFollowing = false
                self.relationship = relationship
                onFollowed(relationship)
                logger.info("listMembership follow done")
                if availability == .available {
                    send(.add, listID: listID)
                }
            } catch {
                isFollowing = false
                guard let presentation = handle(error, during: "follow") else { return }
                onFailure(.follow, presentation)
            }
        }
    }

    /// リストを作り、シートの並びに足す。作れなければ投げる。入れた名前を残して入力に戻すのと、タブの並びに足すのは、呼んだ側が行う。
    /// 作ったリストにその人を足すのは、呼んだ側が`toggle`で行う。フォローの確かめも、ふだんと同じ道を通すため。
    public func create(title: String) async throws -> MastodonList {
        do {
            let list = try await api.create(title)
            lists.append(list)
            logger.info("listMembership create done")
            return list
        } catch {
            _ = handle(error, during: "create")
            throw error
        }
    }

    private enum Change {
        case add
        case remove

        var operation: Operation {
            switch self {
            case .add: .add
            case .remove: .remove
            }
        }
    }

    private func send(_ change: Change, listID: String) {
        switch change {
        case .add: memberListIDs.insert(listID)
        case .remove: memberListIDs.remove(listID)
        }
        nextSelection += 1
        let selection = nextSelection
        selections[listID] = selection
        let previous = sending[listID]
        let api = api
        // 送り終える前にシートを閉じても、押した足し外しは最後まで送るよう、送り終えるまでモデルを手放さない。
        let task = tasks.run(.action) { [self] in
            await previous?.value
            do {
                switch change {
                case .add: try await api.add(listID)
                case .remove: try await api.remove(listID)
                }
                guard !tasks.isClosed else { return }
                switch change {
                case .add: confirmedListIDs.insert(listID)
                case .remove: confirmedListIDs.remove(listID)
                }
                finish(listID, selection: selection)
                logger.info("listMembership \(change == .add ? "add" : "remove", privacy: .public) done list=\(listID, privacy: .public)")
            } catch {
                guard let presentation = handle(error, during: change == .add ? "add" : "remove") else { return }
                // あとから押し直していなければ、サーバーが受け付けた状態に戻す。
                if selections[listID] == selection {
                    if confirmedListIDs.contains(listID) {
                        memberListIDs.insert(listID)
                    } else {
                        memberListIDs.remove(listID)
                    }
                }
                finish(listID, selection: selection)
                onFailure(change.operation, presentation)
            }
        }
        sending[listID] = task
    }

    private func finish(_ listID: String, selection: Int) {
        guard selections[listID] == selection else { return }
        selections[listID] = nil
        sending[listID] = nil
    }

    /// 失敗をログに残して、知らせる中身を返す。止めたあとや取り消しならnil。
    private func handle(_ error: any Error, during operation: String) -> ErrorPresentation? {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return nil }
        logger.error("listMembership \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        return ErrorPresentation(error)
    }
}
