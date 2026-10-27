import Foundation
import os
import SciaCore
import UIKit

/// 予約した投稿の一覧の読み込みと操作を、`ScheduledStatusesViewController`の表示へつなぐ。決まりはdocs/tabs.mdの「予約投稿」にある。
///
/// ストリームがないため購読せず、開くたびと、開いたままアプリに戻ったときに読み直す。
@MainActor
final class ScheduledStatusesController {
    let viewController: ScheduledStatusesViewController
    private let client: MastodonClient
    /// 行に出す自分のアカウントを返す。セッションが一度読んだものを使い回す。
    private let myAccount: () async throws -> Account
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "scheduled")
    /// 選べる日時と、行の日時の書き方を決める今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now {
        didSet { viewController.now = now }
    }
    private let calendar = Calendar.autoupdatingCurrent
    /// 「投稿欄に戻して書き直す」を選んだときに呼ぶ。下書きを捨ててよいか聞くのも、投稿欄に戻すのも、呼ぶ側。
    var onRewrite: (ScheduledStatus) -> Void = { _ in }
    /// 読み直している途中の読み込み。重ねて読まない。
    private var loading: Task<Void, Never>?
    /// 一度でも読み終えた。読み終える前に予約したものは、読み直しで入るので足さない。
    private var hasLoaded = false
    /// 一覧の中身を手元で変えた回数。読んでいる間に予約、日時の変更、取り消しが済んだら、その前に送った読み込みの応答は古いので使わず、読み直す。
    private var changeCount = 0
    /// 開いて見せている。見せている間にアプリに戻ったら読み直す。
    private var isShown = false
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { tasks.runningCount }

    init(client: MastodonClient, tasks: TaskScope, myAccount: @escaping () async throws -> Account, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.myAccount = myAccount
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
        viewController = ScheduledStatusesViewController(now: AppDependencies.now, calendar: calendar)
        viewController.onAppearing = { [weak self] in
            guard let self else { return }
            isShown = true
            // 初めて開いたときは使う人の操作として読む。読み終えた一覧を開き直したときは、一覧を新しく保つための読み込みにする。
            reload(purpose: hasLoaded ? .display : .action)
        }
        viewController.onDisappearing = { [weak self] in self?.isShown = false }
        viewController.onRefresh = { [weak self] in await self?.reload(purpose: .action)?.value }
        viewController.onRetry = { [weak self] in self?.reload(purpose: .action) }
        viewController.onReschedule = { [weak self] scheduled in self?.presentReschedule(scheduled) }
        viewController.onRewrite = { [weak self] scheduled in self?.onRewrite(scheduled) }
        viewController.onCancel = { [weak self] scheduled in self?.confirmCancel(scheduled) }
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    /// - Parameter purpose: 開き直したときやアプリに戻ったときは`.display`。レート制限で止められている間は送らない。
    @discardableResult
    func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
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

    func enterForeground() {
        guard isShown else { return }
        reload(purpose: .display)
    }

    /// 投稿欄で予約できた。読み終えた一覧なら、読み直さずにその場で入れる。
    func didSchedule(_ scheduled: ScheduledStatus) {
        // 読んでいる途中なら、その応答は予約する前のものなので読み直させる。
        changeCount += 1
        guard hasLoaded else { return }
        viewController.setStatuses(viewController.statuses.filter { $0.id != scheduled.id } + [scheduled], animatingChanges: false)
    }

    /// 書き直した投稿を送れて、元の予約を取り消した。
    func didCancel(_ id: ScheduledStatus.ID) {
        changeCount += 1
        guard hasLoaded else { return }
        viewController.setStatuses(viewController.statuses.filter { $0.id != id }, animatingChanges: false)
    }

    private func load() async {
        if !hasLoaded {
            viewController.setContentState(.loading)
        }
        logger.info("scheduled load start")
        do {
            // 行は自分のアイコンと名前で描くので、読めなければ一覧ごと読めなかったことにする。
            let account = try await myAccount()
            guard !tasks.isClosed else { return }
            viewController.account = account
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
            viewController.setStatuses(statuses, animatingChanges: false)
            viewController.setContentState(.loaded)
            logger.info("scheduled load done count=\(statuses.count, privacy: .public)")
        } catch {
            guard !tasks.isClosed, !(error is CancellationError) else { return }
            logger.error("scheduled load failed: \(SciaLog.describe(error), privacy: .public)")
            reportIfUnauthorized(error)
            // 読めた一覧は消さず、読み直しの失敗はログだけにする。まだ何も読めていなければ、理由を一覧の場所に出す。
            if !hasLoaded {
                viewController.setContentState(.failed(ErrorPresentation(error)))
            }
        }
    }

    private func reportIfUnauthorized(_ error: any Error) {
        if let error = error as? MastodonAPIError, error.isUnauthorized {
            onUnauthorized()
        }
    }

    // MARK: - 日時を変える

    private func presentReschedule(_ scheduled: ScheduledStatus) {
        let sheet = ScheduleDateSheet(
            title: "予約の日時を変える",
            date: scheduled.scheduledAt,
            minimumDate: ScheduledPosting.earliestDate(now: now(), calendar: calendar),
            confirmTitle: "変更"
        ) { [weak self] date in
            self?.reschedule(scheduled, to: date)
        } onClose: {}
        viewController.present(sheet, animated: true)
    }

    private func reschedule(_ scheduled: ScheduledStatus, to date: Date) {
        guard date != scheduled.scheduledAt else { return }
        // 選んでから決めるまでの間に5分を切ったら、送らずに知らせる。サーバーが断るため。
        guard ScheduledPosting.accepts(date, now: now()) else {
            presentFailure(title: "日時を変えられませんでした", message: "予約の日時は、今から5分より後にしてください。")
            return
        }
        logger.info("scheduled reschedule start")
        tasks.run { [weak self, client] in
            do {
                let moved = try await client.rescheduleStatus(scheduled.id, to: date)
                guard let self, !tasks.isClosed else { return }
                logger.info("scheduled reschedule done")
                changeCount += 1
                // 使う人の操作の結果で並びが変わるので、動かして行の行き先を見せる。
                viewController.setStatuses(viewController.statuses.map { $0.id == moved.id ? moved : $0 }, animatingChanges: true)
            } catch {
                guard let self, !tasks.isClosed, !(error is CancellationError) else { return }
                logger.error("scheduled reschedule failed: \(SciaLog.describe(error), privacy: .public)")
                reportIfUnauthorized(error)
                presentFailure(title: "日時を変えられませんでした", message: ErrorPresentation(error).text)
            }
        }
    }

    // MARK: - 取り消す

    private func confirmCancel(_ scheduled: ScheduledStatus) {
        let alert = UIAlertController(title: "予約を取り消しますか？", message: "取り消した予約は投稿されず、元に戻せません。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "取り消す", style: .destructive) { [weak self] _ in
            self?.cancel(scheduled)
        })
        viewController.present(alert, animated: true)
    }

    private func cancel(_ scheduled: ScheduledStatus) {
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
                presentFailure(title: "予約を取り消せませんでした", message: ErrorPresentation(error).text)
                return
            }
            guard let self, !tasks.isClosed else { return }
            logger.info("scheduled cancel done")
            changeCount += 1
            // 使う人の操作の結果で行が消えるので、標準の削除の動きで閉じる。
            viewController.setStatuses(viewController.statuses.filter { $0.id != scheduled.id }, animatingChanges: true)
        }
    }

    private func presentFailure(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        viewController.frontmostPresented.present(alert, animated: true)
    }
}
