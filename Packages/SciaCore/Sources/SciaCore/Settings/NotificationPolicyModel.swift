import Foundation
public import Observation
import os

/// 通知のフィルタリングの設定と、保留中の通知の人数。決まりはdocs/notification-filter.mdにある。
/// セッションに1つ置き、通知のタブのボタンの人数と、設定の画面が同じものを見る。
@MainActor
@Observable
public final class NotificationPolicyModel {
    /// 画面に出す設定。選んだ値は、送り終える前から入れる。まだ読めていなければnil。
    public private(set) var policy: NotificationPolicy?
    /// 最初の読み込みに失敗した理由。読めたらnil。
    public private(set) var loadFailure: ErrorPresentation?
    /// サーバーに通知のフィルタリングがあるか。ないと分かったら（Mastodon 4.2以前）、そのセッションの間はfalseにし、入口を出さない。
    public private(set) var isSupported = true
    /// 保留中の通知を送った人の数。
    public var pendingRequestsCount: Int { policy?.pendingRequestsCount ?? 0 }
    /// サーバーが止める人数。これと同じなら、実際はもっと多いことがある。
    public static let pendingRequestsCap = 100

    /// 設定を送れなかったときに呼ぶ。知らせ方は作る側が決める。
    @ObservationIgnored public var onFailure: (ErrorPresentation) -> Void = { _ in }
    /// サーバーが返した最後の設定。送れなかった項目は、この値に戻す。
    @ObservationIgnored private var confirmed: NotificationPolicy?
    /// 項目ごとに、最後に選んだ回の番号。送り終えたときに、その後に選び直していれば、応答の値で上書きしない。
    @ObservationIgnored private var selections: [NotificationPolicy.Item: Int] = [:]
    @ObservationIgnored private var nextSelection = 0
    /// 送っている途中の設定。順に送り、後から選んだ値を先に届けない。
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let client: MastodonClient
    @ObservationIgnored private let tasks: TaskScope
    @ObservationIgnored private let logger = SciaLog.logger(category: "notificationPolicy")
    public var runningTaskCount: Int { tasks.runningCount }

    public init(client: MastodonClient, tasks: TaskScope) {
        self.client = client
        self.tasks = tasks
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    /// - Parameter purpose: 通知のタイムラインを読み込んだときやアプリに戻ったときは`.display`。
    @discardableResult
    public func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        if let loading { return loading }
        loading = tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer { loading = nil }
            do {
                let selectionsBefore = nextSelection
                let policy = try await client.notificationPolicy()
                guard !tasks.isClosed else { return }
                // 読んでいる間に選んだら、選ぶ前の値で上書きしない。人数だけを入れる。
                guard nextSelection == selectionsBefore else {
                    self.policy = self.policy.map { NotificationPolicy(values: $0.values, pendingRequestsCount: policy.pendingRequestsCount, pendingNotificationsCount: policy.pendingNotificationsCount) }
                    return
                }
                receive(policy)
                loadFailure = nil
                logger.info("notificationPolicy load done pending=\(policy.pendingRequestsCount, privacy: .public)")
            } catch is FeatureUnavailable {
                guard !tasks.isClosed else { return }
                isSupported = false
            } catch {
                guard let presentation = handle(error, during: "load") else { return }
                // 読めた設定は消さず、まだ何も読めていなければ理由を出す。
                if self.policy == nil {
                    loadFailure = presentation
                }
            }
        }
        return loading
    }

    /// 項目の値を選ぶ。すぐ画面に入れ、変えた項目だけを送る。知らない値は選べない。
    @discardableResult
    public func select(_ value: NotificationPolicy.Value, for item: NotificationPolicy.Item) -> Task<Void, Never>? {
        guard value.rawValue != nil, policy != nil, policy?[item] != value else { return nil }
        policy?[item] = value
        nextSelection += 1
        let selection = nextSelection
        selections[item] = selection
        let previous = sending
        logger.info("notificationPolicy select item=\(item.rawValue, privacy: .public) value=\(value.rawValue ?? "", privacy: .public)")
        let task = tasks.run(.action) { [weak self] in
            await previous?.value
            guard let self, !tasks.isClosed else { return }
            // 送る前に同じ項目を選び直していれば、後の回に任せる。
            guard selections[item] == selection else { return }
            do {
                let saved = try await client.updateNotificationPolicy([item: value])
                guard !tasks.isClosed else { return }
                if selections[item] == selection {
                    selections[item] = nil
                }
                receive(saved)
            } catch {
                guard let presentation = handle(error, during: "update") else { return }
                if selections[item] == selection {
                    selections[item] = nil
                    policy?[item] = confirmed?[item]
                }
                onFailure(presentation)
            }
        }
        sending = task
        return task
    }

    /// 受け入れや無視で人数が変わった。読み直す。
    public func requestsDidChange() {
        reload(purpose: .display)
    }

    /// サーバーの値を入れる。選んで送り終えていない項目は、選んだ値のまま残す。
    private func receive(_ server: NotificationPolicy) {
        confirmed = server
        var shown = server
        for item in selections.keys {
            shown[item] = policy?[item]
        }
        policy = shown
    }

    /// 失敗をログに残して、知らせる中身を返す。止めたあとや取り消しならnil。
    private func handle(_ error: any Error, during operation: String) -> ErrorPresentation? {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return nil }
        logger.error("notificationPolicy \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        return ErrorPresentation(error)
    }
}
