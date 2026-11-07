import SciaCore
import UIKit

/// タイムラインで選んだ投稿に、まとめてブーストや共有をする。選んだタイムラインを離れても続くよう、セッションで持つ。決まりはdocs/batch-actions.mdにある。
@MainActor
final class BatchActionCenter {
    /// 同じ操作の結果を待っている投稿だったので送らなかった。押した操作の結果を待ってから続きを送れば済む。
    private struct Busy: LocalizedError {
        var errorDescription: String? { "この投稿へのほかの操作の結果を待っています。" }
    }

    private static let reblogActivityID = "batch.reblog"
    private static let downloadActivityID = "batch.download"

    private let interactions: StatusInteractions
    private let notices: NoticeCenter
    private let operationStatus: OperationStatus
    private let tasks: TaskScope
    private let clock: any Clock<Duration>
    private let fetch: MediaTransfers.Fetch
    private let describe: @MainActor (any Error) async -> ErrorPresentation

    /// 進んでいるか、失敗して続きを待っているまとめてブースト。
    private var reblog: BatchReblog?
    private var reblogStopConfirmation: UIAlertController?
    private var shareTask: Task<Void, Never>?
    /// 始めたまとめて共有の世代。止めるか新しく始めるたびに進める。
    private var shareGeneration = 0
    private var shareProgress: (completed: Int, total: Int)?
    private var shareStopConfirmation: UIAlertController?

    init(interactions: StatusInteractions, notices: NoticeCenter, operationStatus: OperationStatus, tasks: TaskScope, clock: any Clock<Duration>, fetch: @escaping MediaTransfers.Fetch, describe: @escaping @MainActor (any Error) async -> ErrorPresentation) {
        self.interactions = interactions
        self.notices = notices
        self.operationStatus = operationStatus
        self.tasks = tasks
        self.clock = clock
        self.fetch = fetch
        self.describe = describe
    }

    // MARK: ブースト

    /// 選んだ順にブーストを始める。前のまとめてブーストが残っていれば止めて、新しく選んだものに替える。
    func reblog(_ statuses: [Status], myAccountID: String, visibility: ReblogVisibility) {
        let plan = BatchReblogPlan(statuses: statuses, myAccountID: myAccountID)
        guard !plan.steps.isEmpty else { return }
        reblog?.stop()
        let interactions = interactions
        let run = BatchReblog(
            plan: plan,
            interval: { .seconds(AppDependencies.tuning.value(of: TuningCatalog.batchReblogInterval)) },
            clock: clock,
            isRemovalPending: { ($0 as? MastodonAPIError)?.statusCode == 422 },
            isReblogged: { interactions.mayBeReblogged($0) }
        ) { status in
            guard try await interactions.set(.reblog, to: false, on: status) else { throw Busy() }
        } reblog: { status in
            guard try await interactions.set(.reblog, to: true, on: status, reblogVisibility: visibility) else { throw Busy() }
        }
        run.onProgress = { [weak self] in self?.showReblogProgress() }
        reblog = run
        resumeReblog(run)
    }

    /// `run`の残りを送る。失敗したあとの「続きからブースト」でも呼ぶ。新しいまとめてブーストに替わっていたら何もしない。
    private func resumeReblog(_ run: BatchReblog) {
        // 失敗のチップを続けて押しても、走っている続きに重ねない。
        guard reblog === run, !run.isRunning else { return }
        showReblogProgress()
        tasks.run(.action) { [weak self] in
            let outcome = await run.run()
            // 走っている続きの進み具合は、その続きが終わったときに消す。
            guard let self, reblog === run, !outcome.isAlreadyRunning else { return }
            endReblogProgress()
            switch outcome {
            case .finished, .stopped, .alreadyRunning:
                reblog = nil
            case .failed(let index, let error):
                await reblogDidFail(run, at: index, error)
            }
        }
    }

    private func showReblogProgress() {
        guard let run = reblog else { return }
        let fraction = run.total > 0 ? Double(run.completedCount) / Double(run.total) : nil
        operationStatus.update(OperationStatus.Activity(id: Self.reblogActivityID, title: "ブースト中", value: "\(run.completedCount)/\(run.total)", fraction: fraction)) { [weak run] in
            run?.stop()
        }
        notices.setPersistent({ [weak self, weak run] _ in
            guard let run else { return nil }
            return .batchReblog(completed: run.completedCount, total: run.total) { self?.confirmStoppingReblog() }
        }, in: .batchReblog)
    }

    private func endReblogProgress() {
        operationStatus.end(Self.reblogActivityID)
        notices.setPersistent(nil, in: .batchReblog)
        reblogStopConfirmation?.dismiss(animated: true)
        reblogStopConfirmation = nil
    }

    /// 失敗したところで止め、数秒で消えるチップで知らせる。押すと理由と「続きからブースト」を出す。
    /// 理由を待つ間に新しいまとめてブーストを始めていたら、失敗は残すが、チップは出さない。続きを送る先がもうないため。
    private func reblogDidFail(_ run: BatchReblog, at index: Int, _ error: any Error) async {
        let title = Notice.batchReblogFailureTitle(index: index)
        let subject = OperationStatus.Subject(run.steps[index].status)
        let reason = await describe(error)
        operationStatus.recordFailure(title: title, reason: reason, subject: subject)
        guard reblog === run else { return }
        notices.showTransient(.interactionFailure(title: title) { [weak self, weak run] in
            guard let run else { return }
            self?.presentReblogFailure(run, title: title, reason: reason)
        }, duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    private func presentReblogFailure(_ run: BatchReblog, title: String, reason: ErrorPresentation) {
        let resume = reblog === run ? [UIAlertAction(title: "続きからブースト", style: .default) { [weak self] _ in self?.resumeReblog(run) }] : []
        present(UIAlertController.failure(title: title, reason: reason, actions: resume, cancelTitle: "閉じる"))
    }

    private func confirmStoppingReblog() {
        guard reblog != nil, reblogStopConfirmation == nil else { return }
        // チップから吹き出すシートでは「続ける」が省かれ、外をタップして続けることになるため、両方を並べるアラートにする。
        let alert = UIAlertController(title: "まとめてブーストを中止しますか？", message: "ブーストし終えた投稿はそのまま残ります。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "中止", style: .destructive) { [weak self] _ in
            self?.reblogStopConfirmation = nil
            self?.reblog?.stop()
        })
        alert.addAction(UIAlertAction(title: "続ける", style: .cancel) { [weak self] _ in self?.reblogStopConfirmation = nil })
        reblogStopConfirmation = alert
        present(alert)
    }

    // MARK: 共有

    /// 選んだ順の本文とメディアを、共有のシートに1回で渡す。メディアは落としてから渡す。前のまとめて共有が落としている途中なら止める。
    /// 共有のシートは、いちばん手前の画面から出す。選び終えるとツールバーは消え、落としている間に画面を移ることもあるため。
    func share(_ statuses: [Status]) {
        let payload = BatchSharePayload(statuses: statuses)
        stopSharing()
        guard !payload.media.isEmpty else {
            presentShareSheet(text: payload.text, files: [])
            return
        }
        let fetch = fetch
        shareGeneration += 1
        let generation = shareGeneration
        shareProgress = (0, payload.media.count)
        showDownloadProgress()
        // 止めたり新しく始めたりした共有の処理が、あとから今の共有の進み具合やチップを変えないよう、始めたときの世代で見分ける。
        shareTask = tasks.run(.action) { [weak self] in
            do {
                let files = try await BatchShareDownload.fetchAll(payload.media, fetch: fetch) { [weak self] completed, fraction in
                    guard let self, shareGeneration == generation else { return }
                    shareProgress = (completed, payload.media.count)
                    showDownloadProgress(fraction: fraction)
                }
                guard let self, shareGeneration == generation, !Task.isCancelled else { return }
                shareTask = nil
                endDownloadProgress {
                    self.presentShareSheet(text: payload.text, files: files)
                }
            } catch {
                guard let self, shareGeneration == generation, !Task.isCancelled, !(error is CancellationError) else { return }
                shareTask = nil
                endDownloadProgress()
                let title = Notice.batchShareFailureTitle
                let reason = await describe(error)
                operationStatus.recordFailure(title: title, reason: reason)
                notices.showTransient(.interactionFailure(title: title) { [weak self] in
                    self?.present(UIAlertController.failure(title: title, reason: reason))
                }, duration: AppDependencies.tuning.value(of: TuningCatalog.noticeFailureChipDuration))
            }
        }
    }

    /// 落としている途中の共有を止める。止めた処理は世代が古くなるので、あとから戻ってきても何もしない。
    private func stopSharing() {
        shareGeneration += 1
        shareTask?.cancel()
        shareTask = nil
        endDownloadProgress()
    }

    private func showDownloadProgress(fraction: Double? = nil) {
        guard let progress = shareProgress else { return }
        operationStatus.update(OperationStatus.Activity(id: Self.downloadActivityID, title: "ダウンロード中", value: "\(progress.completed)/\(progress.total)", fraction: fraction)) { [weak self] in
            self?.stopSharing()
        }
        notices.setPersistent({ [weak self] _ in
            guard let progress = self?.shareProgress else { return nil }
            return .batchDownload(completed: progress.completed, total: progress.total) { self?.confirmStoppingShare() }
        }, in: .batchShare)
    }

    /// 進み具合を消し、止めるかの確認を開いていれば閉じてから`next`を行う。
    /// 確認の上から共有のシートを出すと、確認を閉じるときに一緒に閉じられるか、出せずに終わるため。
    private func endDownloadProgress(then next: @escaping @MainActor () -> Void = {}) {
        if shareProgress != nil {
            shareProgress = nil
            operationStatus.end(Self.downloadActivityID)
            notices.setPersistent(nil, in: .batchShare)
        }
        guard let confirmation = shareStopConfirmation else {
            next()
            return
        }
        shareStopConfirmation = nil
        guard confirmation.presentingViewController != nil else {
            next()
            return
        }
        confirmation.dismiss(animated: true, completion: next)
    }

    private func confirmStoppingShare() {
        guard shareTask != nil, shareStopConfirmation == nil else { return }
        let alert = UIAlertController(title: "ダウンロードを中止しますか？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "中止", style: .destructive) { [weak self] _ in
            self?.shareStopConfirmation = nil
            self?.stopSharing()
        })
        alert.addAction(UIAlertAction(title: "続ける", style: .cancel) { [weak self] _ in self?.shareStopConfirmation = nil })
        shareStopConfirmation = alert
        present(alert)
    }

    private func presentShareSheet(text: String?, files: [URL]) {
        let items: [Any] = (text.map { [$0] } ?? []) + files
        guard !items.isEmpty, let presenter = notices.presenter?.frontmostPresented else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // 添付ファイルの画像を連絡先の写真にすることはまずないため、出さない。メディアの共有と同じ。
        activity.excludedActivityTypes = [.assignToContact]
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private func present(_ alert: UIAlertController) {
        notices.presenter?.frontmostPresented.present(alert, animated: true)
    }
}
