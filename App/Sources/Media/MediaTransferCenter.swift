import os
import SciaCore
import UIKit

/// 共有や保存のために添付ファイルを落とす処理の知らせを、開いているビューアか一覧に出す。セッションごとに1つ持ち、ビューアを閉じても保存を続ける。
/// 決まりはdocs/notices.mdの「場面ごと」の「ダウンロード」と「複数のダウンロード」にある。
///
/// ビューアを開いている間は、済んだことや失敗をビューアに出す。閉じたあとは、一覧（タイムライン）の知らせの場所に出す。
/// 落としている途中のチップは、ビューアにはいま見ている添付ファイルのものを、一覧には1件なら進み具合を、2件以上なら件数を出す。
/// 落としている途中のものは「最近の失敗」の一覧の「進行中」にも並べ、行から止められるようにする。
@MainActor
final class MediaTransferCenter {
    /// ビューアを閉じているときに知らせを出す先。
    struct Host {
        /// 落としている途中のチップを、すべての一覧に出す。nilなら消す。
        let setPersistent: @MainActor (Notice?) -> Void
        /// 数秒で消えるチップを、見えている一覧に出す。`replacesChip`なら、落としている途中のチップをその場所で入れ替える。
        let showTransient: @MainActor (_ notice: Notice, _ duration: TimeInterval, _ replacesChip: Bool) -> Void
        /// いちばん手前の画面。アラートや「最近の失敗」の一覧を、この上に出す。
        let presenter: @MainActor () -> UIViewController?
    }

    let transfers: MediaTransfers
    /// 落としている途中のものと失敗を並べる「最近の失敗」。
    private let recentNotices: RecentNotices
    private let tuning: TuningStore
    /// 「最近の失敗」の一覧を開く。nilなら開けないため、出たままの知らせが2件以上でもチップを押すと止めるかの確認を出す。
    var showRecentNotices: (@MainActor (UIViewController) -> Void)?
    var host: Host? {
        didSet { updateTimelineChip() }
    }
    /// 開いているビューア。Macではビューアを別々のウィンドウで開くため、いくつも開いていることがある。
    private let openViewers = NSHashTable<MediaViewerController>.weakObjects()
    /// 落としているものごとの、最後にその操作を始めたビューア。開いている間は、済んだことや失敗をそのビューアに出す。
    private var requesters: [MediaTransfers.Transfer.ID: WeakViewer] = [:]

    private struct WeakViewer {
        weak var viewer: MediaViewerController?
    }
    /// 落としている途中のチップを押して出した、止めるかの確認と、その対象。対象が済むか止まったら閉じる。
    private weak var stopConfirmation: UIAlertController?
    private var stopConfirmationTarget: MediaTransfers.Transfer.ID?
    /// 「最近の失敗」の「進行中」に並べているもの。
    private var listedActivities: Set<RecentNotices.Activity.ID> = []
    private let logger = SciaLog.logger(category: "media")

    init(recentNotices: RecentNotices, tuning: TuningStore = AppDependencies.tuning, transfers: MediaTransfers) {
        self.recentNotices = recentNotices
        self.tuning = tuning
        self.transfers = transfers
        transfers.onChange = { [weak self] in self?.transfersDidChange() }
        transfers.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// アプリの通信と写真ライブラリを使う。
    convenience init(recentNotices: RecentNotices, downloads: MediaDownloads = AppDependencies.mediaDownloads, photoSaver: PhotoLibrarySaver = .photoLibrary) {
        self.init(recentNotices: recentNotices, transfers: MediaTransfers(
            fetch: { url, onProgress in try await downloads.fileForSharing(for: url, onProgress: onProgress) },
            saveToPhotos: { file in try await photoSaver.save(file) }
        ))
    }

    // MARK: ビューア

    /// ビューアを開いた。閉じるまで、そのビューアで始めたものの知らせをビューアに出す。
    func viewerDidOpen(_ viewer: MediaViewerController) {
        openViewers.add(viewer)
    }

    /// ビューアを閉じた。そのビューアで共有のために落としている途中のものを止め、保存のためのものは続ける。
    func viewerDidClose(_ viewer: MediaViewerController) {
        guard openViewers.contains(viewer) else { return }
        openViewers.remove(viewer)
        transfers.stopSharing { [requesters] in requesters[$0.id]?.viewer === viewer }
    }

    func start(_ purpose: MediaTransfers.Purpose, _ target: MediaTransfers.Target, from viewer: MediaViewerController) {
        logger.info("start media transfer purpose=\(String(describing: purpose), privacy: .public) kind=\(String(describing: target.kind), privacy: .public)")
        // 開き終える前に始めてすぐ済んでも、知らせの届け先を失わないよう、始めたビューアは開いているものとして扱う。
        openViewers.add(viewer)
        let id = transfers.start(purpose, target)
        requesters[id] = WeakViewer(viewer: viewer)
    }

    /// `transfer`を始めたビューア。閉じていればnil。
    private func viewer(of transfer: MediaTransfers.Transfer) -> MediaViewerController? {
        guard let viewer = requesters[transfer.id]?.viewer, openViewers.contains(viewer) else { return nil }
        return viewer
    }

    /// ビューアのチップ。いま見ている添付ファイルのものを出し、ほかは件数で添える。
    /// 2件以上のときに押したら、`presenter`の上に「最近の失敗」の一覧を開く。
    func viewerChipNotice(currentURL: URL?, presenter: UIViewController) -> Notice? {
        MediaTransferChip.viewer(transfers.transfers, currentURL: currentURL).map { notice(for: $0, presenter: presenter) }
    }

    // MARK: 知らせ

    private func transfersDidChange() {
        updateActivities()
        updateTimelineChip()
        requesters = requesters.filter { id, _ in transfers.transfer(id) != nil }
        for viewer in openViewers.allObjects {
            viewer.transferNoticesDidChange()
        }
        closeStopConfirmationIfDone()
    }

    /// 一覧のチップを出し直す。一覧を足したときにも呼ぶ。
    func updateTimelineChip() {
        guard let host else { return }
        let chip = MediaTransferChip.timeline(transfers.transfers)
        host.setPersistent(chip.map { [weak self] chip in
            guard let self else { return nil }
            return self.notice(for: chip) { [weak self] in self?.host?.presenter() }
        } ?? nil)
    }

    private func notice(for chip: MediaTransferChip, presenter: UIViewController) -> Notice {
        notice(for: chip) { [weak presenter] in presenter }
    }

    /// 1件だけなら、押すと止めるかの確認を出す。2件以上なら、押すと「最近の失敗」の一覧を開く。
    private func notice(for chip: MediaTransferChip, presenter: @escaping @MainActor () -> UIViewController?) -> Notice {
        var showAll: (@MainActor () -> Void)?
        if let show = showRecentNotices {
            showAll = {
                if let presenter = presenter() {
                    show(presenter)
                }
            }
        }
        switch chip {
        case .single(let transfer, let others):
            var onStop: (@MainActor () -> Void)?
            if transfer.isStoppable {
                onStop = { [weak self] in
                    guard let presenter = presenter() else { return }
                    self?.confirmStopping(transfer.id, from: presenter)
                }
            }
            var notice = Notice.download(of: transfer.target.url, fraction: transfer.fraction ?? 0, onStop: onStop)
            notice.additionalCount = others
            if others > 0, let showAll {
                notice.action = .disclosure(hint: "最近の失敗の一覧を開きます。", handler: showAll)
            }
            return notice
        case .count(let count):
            let only = transfers.transfers.filter(\.isVisible)
            let action: Notice.Action
            if count > 1, let showAll {
                action = .disclosure(hint: "最近の失敗の一覧を開きます。", handler: showAll)
            } else if let transfer = only.last, transfer.isStoppable {
                action = .disclosure(hint: "ダウンロードを止めるか選べます。") { [weak self] in
                    guard let presenter = presenter() else { return }
                    self?.confirmStopping(transfer.id, from: presenter)
                }
            } else {
                action = .none
            }
            return .downloads(count: count, action: action)
        }
    }

    /// 「最近の失敗」の「進行中」の行を、落としている途中のものに合わせる。
    private func updateActivities() {
        var current: Set<RecentNotices.Activity.ID> = []
        for transfer in transfers.transfers where transfer.isVisible {
            let id = "media.transfer.\(transfer.id.uuidString)"
            current.insert(id)
            let activity = RecentNotices.Activity(
                id: id,
                title: "ダウンロード中",
                value: Notice.percentText(of: transfer.fraction ?? 0),
                subject: transfer.target.subject
            )
            var onStop: (@MainActor () -> Void)?
            if transfer.isStoppable {
                let id = transfer.id
                onStop = { [weak self] in self?.transfers.stop(id) }
            }
            recentNotices.update(activity, onStop: onStop)
        }
        for id in listedActivities.subtracting(current) {
            recentNotices.end(id)
        }
        listedActivities = current
    }

    private func handle(_ event: MediaTransfers.Event) {
        switch event {
        case .saved(let transfer):
            didSave(transfer)
        case .shareReady(let transfer, let file):
            afterClosingStopConfirmation(of: transfer.id) { [weak viewer = viewer(of: transfer)] in
                viewer?.presentShareSheet(for: file, of: transfer.target.url)
            }
        case .failed(let transfer, let purpose, let failure):
            didFail(transfer, purpose: purpose, failure: failure)
        case .shareStopped(let transfer):
            showTransient(.shareStopped, for: transfer, duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
        }
    }

    /// 写真に保存したことを知らせる。落としている途中のチップがこれで消えるなら、その場所で入れ替える。
    private func didSave(_ transfer: MediaTransfers.Transfer) {
        if let view = viewer(of: transfer)?.viewIfLoaded ?? host?.presenter()?.viewIfLoaded {
            UINotificationFeedbackGenerator(view: view).notificationOccurred(.success)
        }
        showTransient(.savedToPhotos, for: transfer, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
    }

    private func didFail(_ transfer: MediaTransfers.Transfer, purpose: MediaTransfers.Purpose, failure: MediaTransfers.Failure) {
        let viewer = viewer(of: transfer)
        if let view = viewer?.viewIfLoaded ?? host?.presenter()?.viewIfLoaded {
            UINotificationFeedbackGenerator(view: view).notificationOccurred(.error)
        }
        let reason: ErrorPresentation
        switch failure {
        case .download(let error):
            logger.error("media transfer download failed: \(SciaLog.describe(error), privacy: .public)")
            reason = ErrorPresentation(error)
        case .save(let error):
            logger.error("save to photos failed: \(SciaLog.describe(error), privacy: .public)")
            // 設定を変えないと直らないため、アラートで設定を開く案内を出す。
            if error is PhotoLibrarySaver.NotAuthorized {
                afterClosingStopConfirmation(of: transfer.id) { [weak self, weak viewer] in self?.present(Self.notAuthorizedAlert(), on: viewer) }
                return
            }
            reason = PhotoLibrarySaver.failurePresentation(of: error)
        }
        // 「最近の失敗」では投稿を添えるが、どの添付ファイルかは種類で分かるようにする。
        recentNotices.recordFailure(title: Notice.transferFailureTitle(of: transfer.target.kind, purpose: purpose), reason: reason, subject: transfer.target.subject)
        let isCurrent = viewer?.currentTransferURL == transfer.target.url
        let title = isCurrent ? Notice.currentTransferFailureTitle(failure) : Notice.transferFailureTitle(of: transfer.target.kind, purpose: purpose)
        let notice = Notice.transferFailure(title: title) { [weak self, weak viewer] in
            let alert = UIAlertController(title: title, message: reason.text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            self?.present(alert, on: viewer)
        }
        showTransient(notice, for: transfer, duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration))
    }

    /// `transfer`を始めたビューアが開いていればそこに、閉じていれば見えている一覧に出す。落としている途中のチップが消えるなら、その場所で入れ替える。
    /// 呼ぶ時点で、済んだものは`transfers`から外してある。
    private func showTransient(_ notice: Notice, for transfer: MediaTransfers.Transfer, duration: TimeInterval) {
        if let viewer = viewer(of: transfer) {
            viewer.showTransientNotice(notice, duration: duration)
        } else if let host {
            host.showTransient(notice, duration, MediaTransferChip.timeline(transfers.transfers) == nil)
        }
    }

    private static func notAuthorizedAlert() -> UIAlertController {
        let alert = UIAlertController(title: "写真に保存できません", message: "写真への追加が許可されていません。設定でSciaに写真の追加を許可してください。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "設定を開く", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        return alert
    }

    /// `viewer`が開いていればそこから、閉じていればいちばん手前の画面から出す。ビューアの上に代替テキストや共有のシートを開いていれば、その上に出す。
    private func present(_ viewController: UIViewController, on viewer: MediaViewerController?) {
        guard var presenter = viewer.flatMap({ openViewers.contains($0) ? $0 : nil }) ?? host?.presenter() else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(viewController, animated: true)
    }

    // MARK: 止めるかの確認

    /// 落としている途中のチップを押したときに、止めるかを確かめる。
    func confirmStopping(_ id: MediaTransfers.Transfer.ID, from presenter: UIViewController) {
        guard transfers.transfer(id)?.isStoppable == true, stopConfirmation == nil else { return }
        // チップから吹き出すシートでは「続ける」が省かれ、外をタップして続けることになるため、両方を並べるアラートにする。
        let alert = UIAlertController(title: "ダウンロードを止めますか？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "止める", style: .destructive) { [weak self] _ in self?.transfers.stop(id) })
        alert.addAction(UIAlertAction(title: "続ける", style: .cancel))
        stopConfirmation = alert
        stopConfirmationTarget = id
        var top = presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }

    /// 確かめている対象が済むか止まったら、確認を閉じる。
    private func closeStopConfirmationIfDone() {
        guard let id = stopConfirmationTarget, transfers.transfer(id)?.isStoppable != true else { return }
        afterClosingStopConfirmation(of: id) {}
    }

    /// 止めるかの確認を`id`について開いていれば閉じ、閉じ終えてから`next`を行う。開いていなければすぐ行う。
    /// 確認の上から共有のシートや失敗のアラートを出すと、確認を閉じるときに一緒に閉じられるか、出せずに終わるため。
    private func afterClosingStopConfirmation(of id: MediaTransfers.Transfer.ID, then next: @escaping @MainActor () -> Void) {
        guard stopConfirmationTarget == id else {
            next()
            return
        }
        let confirmation = stopConfirmation
        stopConfirmation = nil
        stopConfirmationTarget = nil
        guard let confirmation, confirmation.presentingViewController != nil else {
            next()
            return
        }
        // 出る途中や、「続ける」で閉じる途中なら、その動きを終えてから閉じる。出る途中に閉じると、閉じる指示が捨てられる。
        if let coordinator = confirmation.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak confirmation] _ in
                Self.dismissIfPresented(confirmation, then: next)
            }
        } else {
            Self.dismissIfPresented(confirmation, then: next)
        }
    }

    /// 続けて共有のシートなどを出すため、閉じる動きを待たせないよう動かさずに閉じる。
    private static func dismissIfPresented(_ viewController: UIViewController?, then next: @escaping @MainActor () -> Void) {
        guard let viewController, viewController.presentingViewController != nil else {
            next()
            return
        }
        viewController.dismiss(animated: false) { next() }
    }
}
