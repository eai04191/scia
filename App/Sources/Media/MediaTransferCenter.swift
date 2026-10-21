import os
import SciaCore
import UIKit

/// 共有や保存のために添付ファイルを落とす処理のアプリ内通知を、アプリ全体のチップの列に出す。セッションごとに1つ持ち、ビューアを閉じても保存を続ける。
/// 決まりはdocs/notices.mdの「場面ごと」の「ダウンロード」と「複数のダウンロード」にある。
///
/// 文言は前に出ている画面の様子で決める。ビューアでは、落としている途中のチップにはいま見ている添付ファイルのものを出し、ほかは件数で添える。
/// ビューアでなければ、1件なら進み具合を、2件以上なら件数を出す。済んだことや失敗は、いま見ている添付ファイルなら何ができなかったかだけを、ほかは種類で示す。
/// 落としている途中のものは「操作の状況」の一覧の「進行中」にも並べ、行から止められるようにする。
@MainActor
final class MediaTransferCenter {
    let transfers: MediaTransfers
    /// アプリ内通知を出す先。
    let notices: NoticeCenter
    /// 落としている途中のものと失敗を並べる「操作の状況」。
    private let operationStatus: OperationStatus
    private let tuning: TuningStore
    /// 開いているビューア。Macではビューアを別々のウィンドウで開くため、いくつも開いていることがある。
    private let openViewers = NSHashTable<MediaViewerController>.weakObjects()
    /// 落としているものごとの、最後にその操作を始めたビューアか、一覧のメニューを出したサムネイル。
    /// ビューアが開いている間は、共有のシートと理由のアラートをそのビューアに出す。サムネイルなら、共有のシートをそこから出す。
    private var requesters: [MediaTransfers.Transfer.ID: Requester] = [:]

    private struct Requester {
        weak var viewer: MediaViewerController?
        /// 一覧のメニューから始めた。起点のサムネイルが先に解放されても、ビューアのものと取り違えずに共有のシートを出すため、起点とは別に持つ。
        var isFromMenu = false
        weak var source: (any MediaViewerSource)?
        /// 一覧のメニューから共有を始めたときに、サムネイルが描いていた画像。落としている間にセルが別の投稿に使い回されても、
        /// 共有シートには始めたときの画像を添え、別の画像を出しているサムネイルを起点にしないために持つ。
        var preview: UIImage?
    }
    /// 落としている途中のチップを押して出した、止めるかの確認と、その対象。対象が済むか止まったら閉じる。
    private weak var stopConfirmation: UIAlertController?
    private var stopConfirmationTarget: MediaTransfers.Transfer.ID?
    /// 「操作の状況」の「進行中」に並べているもの。
    private var listedActivities: Set<OperationStatus.Activity.ID> = []
    private let logger = SciaLog.logger(category: "media")

    init(operationStatus: OperationStatus, notices: NoticeCenter, tuning: TuningStore = AppDependencies.tuning, transfers: MediaTransfers) {
        self.operationStatus = operationStatus
        self.notices = notices
        self.tuning = tuning
        self.transfers = transfers
        transfers.onChange = { [weak self] in self?.transfersDidChange() }
        transfers.onEvent = { [weak self] event in self?.handle(event) }
        notices.setPersistent({ [weak self] context in self?.chipNotice(in: context) }, in: .download)
    }

    /// アプリの通信と写真ライブラリを使う。
    convenience init(operationStatus: OperationStatus, notices: NoticeCenter, downloads: MediaDownloads = AppDependencies.mediaDownloads, photoSaver: PhotoLibrarySaver = .photoLibrary) {
        self.init(operationStatus: operationStatus, notices: notices, transfers: MediaTransfers(
            fetch: { url, onProgress in try await downloads.fileForSharing(for: url, onProgress: onProgress) },
            saveToPhotos: { file in try await photoSaver.save(file) }
        ))
    }

    // MARK: ビューア

    /// ビューアを開いた。閉じるまで、そのビューアで始めたものの共有のシートや理由をビューアに出す。
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
        // 開き終える前に始めてすぐ済んでも、届け先を失わないよう、始めたビューアは開いているものとして扱う。
        openViewers.add(viewer)
        let id = transfers.start(purpose, target)
        requesters[id] = Requester(viewer: viewer)
    }

    /// 一覧のメディアのメニューから始めた。ビューアを開いていないので、共有のシートは前に出ている画面から、`source`を起点に出す。
    /// ビューアと違い、閉じて共有をやめる操作がないため、共有のためのものも済むまで続ける。
    /// - Parameters:
    ///   - source: 長押ししたサムネイル。カスタム絵文字のように、起点にできるビューがなければnil。
    ///   - preview: 共有のシートの見出しに添える画像。サムネイルを起点にするときは、サムネイルが描いている画像を渡す。
    func start(_ purpose: MediaTransfers.Purpose, _ target: MediaTransfers.Target, from source: (any MediaViewerSource)?, preview: UIImage?) {
        logger.info("start media transfer from menu purpose=\(String(describing: purpose), privacy: .public) kind=\(String(describing: target.kind), privacy: .public)")
        let id = transfers.start(purpose, target)
        requesters[id] = Requester(isFromMenu: true, source: source, preview: preview)
    }

    /// `transfer`を始めたビューア。閉じていればnil。
    private func viewer(of transfer: MediaTransfers.Transfer) -> MediaViewerController? {
        guard let viewer = requesters[transfer.id]?.viewer, openViewers.contains(viewer) else { return nil }
        return viewer
    }

    // MARK: アプリ内通知

    private func transfersDidChange() {
        updateActivities()
        requesters = requesters.filter { id, _ in transfers.transfer(id) != nil }
        notices.persistentDidChange()
        closeStopConfirmationIfDone()
    }

    /// 前の画面の様子が`context`のときの、落としている途中のチップ。落としているものがなければnil。
    func chipNotice(in context: NoticeContext) -> Notice? {
        let chip = if let viewer = context.viewer {
            MediaTransferChip.viewer(transfers.transfers, currentURL: viewer.currentURL)
        } else {
            MediaTransferChip.timeline(transfers.transfers)
        }
        return chip.map { notice(for: $0) { context.presenter } }
    }

    /// 1件だけなら、押すと止めるかの確認を出す。2件以上なら、押すと「操作の状況」の一覧を開く。
    private func notice(for chip: MediaTransferChip, presenter: @escaping @MainActor () -> UIViewController?) -> Notice {
        var showAll: (@MainActor () -> Void)?
        if let show = notices.showOperationStatus {
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
                notice.action = .disclosure(hint: "操作の状況を開きます。", handler: showAll)
            }
            return notice
        case .count(let count):
            let only = transfers.transfers.filter(\.isVisible)
            let action: Notice.Action
            if count > 1, let showAll {
                action = .disclosure(hint: "操作の状況を開きます。", handler: showAll)
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

    /// 「操作の状況」の「進行中」の行を、落としている途中のものに合わせる。
    private func updateActivities() {
        var current: Set<OperationStatus.Activity.ID> = []
        for transfer in transfers.transfers where transfer.isVisible {
            let id = "media.transfer.\(transfer.id.uuidString)"
            current.insert(id)
            let activity = OperationStatus.Activity(
                id: id,
                title: "ダウンロード中",
                value: Notice.percentText(of: transfer.fraction ?? 0),
                // 全体の大きさが分かるまでは0のため、0%に止まった輪にせず、分からない進み具合として回す。
                fraction: transfer.fraction == 0 ? nil : transfer.fraction,
                subject: transfer.target.subject
            )
            var onStop: (@MainActor () -> Void)?
            if transfer.isStoppable {
                let id = transfer.id
                onStop = { [weak self] in self?.transfers.stop(id) }
            }
            operationStatus.update(activity, onStop: onStop)
        }
        for id in listedActivities.subtracting(current) {
            operationStatus.end(id)
        }
        listedActivities = current
    }

    private func handle(_ event: MediaTransfers.Event) {
        switch event {
        case .saved(let transfer):
            didSave(transfer)
        case .shareReady(let transfer, let file):
            if let requester = requesters[transfer.id], requester.isFromMenu {
                let preview = requester.preview
                afterClosingStopConfirmation(of: transfer.id) { [weak self, weak source = requester.source] in
                    self?.presentShareSheet(for: file, from: source, startedWith: preview)
                }
                return
            }
            afterClosingStopConfirmation(of: transfer.id) { [weak viewer = viewer(of: transfer)] in
                viewer?.presentShareSheet(for: file, of: transfer.target.url)
            }
        case .failed(let transfer, let purpose, let failure):
            didFail(transfer, purpose: purpose, failure: failure)
        case .shareStopped:
            showTransient(duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration)) { _ in .shareStopped }
        }
    }

    /// 写真に保存したことを知らせる。落としている途中のチップがこれで消えるなら、その場所で入れ替える。
    private func didSave(_ transfer: MediaTransfers.Transfer) {
        if let view = viewer(of: transfer)?.viewIfLoaded ?? notices.presenter?.viewIfLoaded {
            UINotificationFeedbackGenerator(view: view).notificationOccurred(.success)
        }
        showTransient(duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration)) { _ in .savedToPhotos }
    }

    private func didFail(_ transfer: MediaTransfers.Transfer, purpose: MediaTransfers.Purpose, failure: MediaTransfers.Failure) {
        let viewer = viewer(of: transfer)
        if let view = viewer?.viewIfLoaded ?? notices.presenter?.viewIfLoaded {
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
        operationStatus.recordFailure(title: Notice.transferFailureTitle(of: transfer.target.kind, purpose: purpose), reason: reason, subject: transfer.target.subject)
        showTransient(duration: tuning.value(of: TuningCatalog.noticeFailureChipDuration)) { [weak self] context in
            let isCurrent = context.viewer?.currentURL == transfer.target.url
            let title = isCurrent ? Notice.currentTransferFailureTitle(failure) : Notice.transferFailureTitle(of: transfer.target.kind, purpose: purpose)
            return Notice.transferFailure(title: title) { [weak self] in
                let alert = UIAlertController(title: title, message: reason.text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                self?.present(alert, onTopOf: context.presenter)
            }
        }
    }

    /// 数秒で消えるチップを出す。呼ぶ時点で、済んだものは`transfers`から外してあるため、落としている途中のチップがこれで消えるなら、その場所で入れ替える。
    private func showTransient(duration: TimeInterval, _ content: @escaping @MainActor (NoticeContext) -> Notice) {
        notices.showTransient(duration: duration, replacing: .download, content)
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

    /// 一覧のメニューから共有するファイルの、共有のシート。見出しのプレビューに、共有を始めたときのサムネイルの画像を添える。
    /// 起点にできるサムネイルがなければ、出す画面の真ん中を起点にする。iPadとMacではポップオーバーで出て、起点がないと例外になるため。
    private func presentShareSheet(for file: URL, from source: (any MediaViewerSource)?, startedWith preview: UIImage?) {
        let content = Self.menuShareSheet(file: file, startedWith: preview, source: source)
        let activity = UIActivityViewController(activityItems: [content.item], applicationActivities: nil)
        // 添付ファイルの画像を連絡先の写真にすることはまずないため、出さない。ビューアと同じ。
        activity.excludedActivityTypes = [.assignToContact]
        guard let presenter = notices.presenter?.frontmostPresented else { return }
        if let popover = activity.popoverPresentationController {
            if let anchor = content.anchor {
                popover.sourceItem = anchor
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(activity, animated: true)
    }

    /// 一覧のメニューから共有するときの、共有シートに渡すものと、ポップオーバーの起点。起点にできなければnil。
    /// 落としている間に行が流れて画面から外れたり、セルが別の投稿に使い回されて別の画像を描いていたりすれば、サムネイルを起点にしない。
    /// 使い回されたかは、始めたときと同じ画像を描いているかで見分ける。
    /// - Parameter preview: 共有を始めたときにサムネイルが描いていた画像。共有シートの見出しにはこれを添える。
    static func menuShareSheet(file: URL, startedWith preview: UIImage?, source: (any MediaViewerSource)?) -> (item: Any, anchor: (any MediaViewerSource)?) {
        let item: Any = preview.map { MediaShareSheetItem(file: file, preview: $0) } ?? file
        guard let preview, let source, source.window != nil, source.loadedThumbnail === preview else { return (item, nil) }
        return (item, source)
    }

    /// `viewer`が開いていればそこから、閉じていればいちばん手前の画面から出す。
    private func present(_ viewController: UIViewController, on viewer: MediaViewerController?) {
        present(viewController, onTopOf: viewer.flatMap { openViewers.contains($0) ? $0 : nil } ?? notices.presenter)
    }

    /// `presenter`の上に代替テキストや共有のシートを開いていれば、その上に出す。
    private func present(_ viewController: UIViewController, onTopOf presenter: UIViewController?) {
        presenter?.frontmostPresented.present(viewController, animated: true)
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
