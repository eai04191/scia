import Foundation
import SciaCore
import UIKit

/// 予約した投稿の画面を組み立て、読み込みと操作を受け持つ`ScheduledStatusesModel`と`ScheduledStatusesViewController`をつなぐ。決まりはdocs/tabs.mdの「予約投稿」にある。
/// 日時を選ぶシート、取り消しの確認、失敗の知らせはここで出す。
@MainActor
final class ScheduledStatusesController {
    let viewController: ScheduledStatusesViewController
    /// 読み込みと、日時の変更や取り消しの通信を受け持つ。
    let model: ScheduledStatusesModel
    /// 選べる日時と、行の日時の書き方を決める今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now {
        didSet { viewController.now = now }
    }
    private let calendar = Calendar.autoupdatingCurrent
    /// 「投稿欄に戻して書き直す」を選んだときに呼ぶ。下書きを捨ててよいか聞くのも、投稿欄に戻すのも、呼ぶ側。
    var onRewrite: (ScheduledStatus) -> Void = { _ in }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    var runningTaskCount: Int { model.runningTaskCount }

    init(client: MastodonClient, tasks: TaskScope, myAccount: @escaping () async throws -> Account, onUnauthorized: @escaping () -> Void) {
        model = ScheduledStatusesModel(client: client, tasks: tasks, myAccount: myAccount, onUnauthorized: onUnauthorized)
        viewController = ScheduledStatusesViewController(now: AppDependencies.now, calendar: calendar)
        model.display = viewController
        model.onFailure = { [weak self] operation, error in
            switch operation {
            case .reschedule: self?.presentFailure(title: "日時を変えられませんでした", message: error.text)
            case .cancel: self?.presentFailure(title: "予約を取り消せませんでした", message: error.text)
            }
        }
        viewController.onAppearing = { [weak model] in model?.appear() }
        viewController.onDisappearing = { [weak model] in model?.disappear() }
        viewController.onRefresh = { [weak model] in await model?.reload(purpose: .action)?.value }
        viewController.onRetry = { [weak model] in model?.reload(purpose: .action) }
        viewController.onReschedule = { [weak self] scheduled in self?.presentReschedule(scheduled) }
        viewController.onRewrite = { [weak self] scheduled in self?.onRewrite(scheduled) }
        viewController.onCancel = { [weak self] scheduled in self?.confirmCancel(scheduled) }
    }

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    @discardableResult
    func reload(purpose: RequestPurpose) -> Task<Void, Never>? {
        model.reload(purpose: purpose)
    }

    func enterForeground() {
        model.enterForeground()
    }

    /// 投稿欄で予約できた。
    func didSchedule(_ scheduled: ScheduledStatus) {
        model.didSchedule(scheduled)
    }

    /// 書き直した投稿を送れて、元の予約を取り消した。
    func didCancel(_ id: ScheduledStatus.ID) {
        model.didCancel(id)
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
        model.reschedule(scheduled, to: date)
    }

    // MARK: - 取り消す

    private func confirmCancel(_ scheduled: ScheduledStatus) {
        let alert = UIAlertController(Confirmation.cancelingSchedule, preferredStyle: .alert) { [weak model] _ in
            model?.cancel(scheduled)
        }
        viewController.present(alert, animated: true)
    }

    private func presentFailure(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        viewController.frontmostPresented.present(alert, animated: true)
    }
}

extension ScheduledStatusesViewController: ScheduledStatusesDisplay {}
