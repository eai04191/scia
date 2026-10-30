public import Foundation
import os

/// 予約した投稿の一覧の状態。投稿がないときの表示に使う。
public enum ScheduledStatusesContentState: Equatable, Sendable {
    case loading
    case loaded
    case failed(ErrorPresentation)
}

/// 予約した投稿の一覧の画面への命令。iOSでは`ScheduledStatusesViewController`が従う。
@MainActor
public protocol ScheduledStatusesDisplay: AnyObject {
    /// 行に出す自分のアカウント。予約を投稿するのは自分なので、投稿されたときと同じく自分のアイコンと名前を出す。
    var account: Account? { get set }
    /// 予約を並べ直す。並べる順は画面が決める。
    /// - Parameter animatingChanges: 使う人の操作の結果（取り消し、日時の変更）なら、行を閉じたり動かしたりする。読み直しでは動かさない。
    func setStatuses(_ statuses: [ScheduledStatus], animatingChanges: Bool)
    func setContentState(_ state: ScheduledStatusesContentState)
}

/// 予約した投稿の一覧の読み込みと、日時の変更や取り消しの通信を受け持ち、結果を一覧の画面（`ScheduledStatusesDisplay`）へ命令として伝える。決まりはdocs/tabs.mdの「予約投稿」にある。
///
/// ストリームがないため購読せず、開くたびと、開いたままアプリに戻ったときに読み直す。
@MainActor
public final class ScheduledStatusesModel {
    /// 失敗を知らせる操作。
    public enum Operation: Sendable {
        case reschedule
        case cancel
    }

    /// 結果を伝える一覧の画面。
    public weak var display: (any ScheduledStatusesDisplay)?
    /// 日時の変更や取り消しに失敗したときに呼ぶ。知らせ方は作る側が決める。
    public var onFailure: (Operation, ErrorPresentation) -> Void = { _, _ in }
    /// 並べている予約。
    public private(set) var statuses: [ScheduledStatus] = []
    private let client: MastodonClient
    /// 行に出す自分のアカウントを返す。セッションが一度読んだものを使い回す。
    private let myAccount: () async throws -> Account
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "scheduled")
    /// 読み直している途中の読み込み。重ねて読まない。
    private var loading: Task<Void, Never>?
    /// 一度でも読み終えた。読み終える前に予約したものは、読み直しで入るので足さない。
    private var hasLoaded = false
    /// 一覧の中身を手元で変えた回数。読んでいる間に予約、日時の変更、取り消しが済んだら、その前に送った読み込みの応答は古いので使わず、読み直す。
    private var changeCount = 0
    /// 開いて見せている。見せている間にアプリに戻ったら読み直す。
    private var isShown = false
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    public init(client: MastodonClient, tasks: TaskScope, myAccount: @escaping () async throws -> Account, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.myAccount = myAccount
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    /// 画面に出るたびに呼ぶ。
    public func appear() {
        isShown = true
        // 初めて開いたときは使う人の操作として読む。読み終えた一覧を開き直したときは、一覧を新しく保つための読み込みにする。
        reload(purpose: hasLoaded ? .display : .action)
    }

    /// 画面から消えたときに呼ぶ。
    public func disappear() {
        isShown = false
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    /// - Parameter purpose: 開き直したときやアプリに戻ったときは`.display`。レート制限で止められている間は送らない。
    @discardableResult
    public func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        if let loading { return loading }
        // 作ったTaskは、作ったときのtask-localの値を引き継ぐ。
        loading = RequestPurpose.$current.withValue(purpose) {
            tasks.run { [weak self] in
                await self?.load()
                self?.loading = nil
            }
        }
        return loading
    }

    public func enterForeground() {
        guard isShown else { return }
        reload(purpose: .display)
    }

    /// 投稿欄で予約できた。読み終えた一覧なら、読み直さずにその場で入れる。
    public func didSchedule(_ scheduled: ScheduledStatus) {
        // 読んでいる途中なら、その応答は予約する前のものなので読み直させる。
        changeCount += 1
        guard hasLoaded else { return }
        setStatuses(statuses.filter { $0.id != scheduled.id } + [scheduled], animatingChanges: false)
    }

    /// 書き直した投稿を送れて、元の予約を取り消した。
    public func didCancel(_ id: ScheduledStatus.ID) {
        changeCount += 1
        guard hasLoaded else { return }
        setStatuses(statuses.filter { $0.id != id }, animatingChanges: false)
    }

    private func setStatuses(_ statuses: [ScheduledStatus], animatingChanges: Bool) {
        self.statuses = statuses
        display?.setStatuses(statuses, animatingChanges: animatingChanges)
    }

    private func load() async {
        if !hasLoaded {
            display?.setContentState(.loading)
        }
        logger.info("scheduled load start")
        do {
            // 行は自分のアイコンと名前で描くので、読めなければ一覧ごと読めなかったことにする。
            let account = try await myAccount()
            guard !tasks.isClosed else { return }
            display?.account = account
            var statuses: [ScheduledStatus]
            repeat {
                let changesBefore = changeCount
                statuses = try await client.scheduledStatuses()
                guard !tasks.isClosed else { return }
                // 読んでいる間に手元で変えたら、その結果を古い応答で戻さないよう、読み直す。
                if changeCount == changesBefore { break }
                logger.info("scheduled load restart after local change")
            } while true
            hasLoaded = true
            // 読み直しで消えたり増えたりする行は、操作によらない変化なので動かさない。
            setStatuses(statuses, animatingChanges: false)
            display?.setContentState(.loaded)
            logger.info("scheduled load done count=\(statuses.count, privacy: .public)")
        } catch {
            guard !tasks.isClosed, !(error is CancellationError) else { return }
            logger.error("scheduled load failed: \(SciaLog.describe(error), privacy: .public)")
            reportIfUnauthorized(error)
            // 読めた一覧は消さず、読み直しの失敗はログだけにする。まだ何も読めていなければ、理由を一覧の場所に出す。
            if !hasLoaded {
                display?.setContentState(.failed(ErrorPresentation(error)))
            }
        }
    }

    private func reportIfUnauthorized(_ error: any Error) {
        if let error = error as? MastodonAPIError, error.isUnauthorized {
            onUnauthorized()
        }
    }

    // MARK: - 日時を変える

    /// 予約の日時を変える。選んだ日時を確かめるのは、呼ぶ側。
    public func reschedule(_ scheduled: ScheduledStatus, to date: Date) {
        logger.info("scheduled reschedule start")
        tasks.run { [weak self, client] in
            do {
                let moved = try await client.rescheduleStatus(scheduled.id, to: date)
                guard let self, !tasks.isClosed else { return }
                logger.info("scheduled reschedule done")
                changeCount += 1
                // 使う人の操作の結果で並びが変わるので、動かして行の行き先を見せる。
                setStatuses(statuses.map { $0.id == moved.id ? moved : $0 }, animatingChanges: true)
            } catch {
                guard let self, !tasks.isClosed, !(error is CancellationError) else { return }
                logger.error("scheduled reschedule failed: \(SciaLog.describe(error), privacy: .public)")
                reportIfUnauthorized(error)
                onFailure(.reschedule, ErrorPresentation(error))
            }
        }
    }

    // MARK: - 取り消す

    /// 予約を取り消す。取り消してよいか聞くのは、呼ぶ側。
    public func cancel(_ scheduled: ScheduledStatus) {
        logger.info("scheduled cancel start")
        tasks.run { [weak self, client] in
            do {
                try await client.cancelScheduledStatus(scheduled.id)
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                // もう投稿されたか、ほかの端末で取り消した。投稿されないことは変わらないので、行を消す。
                self?.logger.info("scheduled cancel found nothing")
            } catch {
                guard let self, !tasks.isClosed, !(error is CancellationError) else { return }
                logger.error("scheduled cancel failed: \(SciaLog.describe(error), privacy: .public)")
                reportIfUnauthorized(error)
                onFailure(.cancel, ErrorPresentation(error))
                return
            }
            guard let self, !tasks.isClosed else { return }
            logger.info("scheduled cancel done")
            changeCount += 1
            // 使う人の操作の結果で行が消えるので、標準の削除の動きで閉じる。
            setStatuses(statuses.filter { $0.id != scheduled.id }, animatingChanges: true)
        }
    }
}
