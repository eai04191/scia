import os
import SciaCore
import UIKit

/// 投稿欄の下に出すシート（メディアを選ぶシート、絵文字のパレットのシート）が開いているか閉じたかを、シートの画面がウィンドウにあるかで決める。
///
/// UIKitの開閉の知らせ（`presentationControllerWillDismiss`、`presentationControllerDidDismiss`、`dismiss`の完了）は、届かないことがある。
/// 実機では、ピッカーの中身を読み込んでいる間に下へスワイプしたときと、閉じる途中に別のシートへ切り替えたときに、知らせのないままシートが消えた。
/// 知らせだけで決めると、投稿欄はシートを出しているつもりのままになり、ボタンが何もしなくなる。知らせは閉じ始めを早く知るためだけに使い、
/// 閉じ終わりは、知らせとウィンドウから外れたことのうち先に来たほうで、一度だけ知らせる。
@MainActor
final class ComposeSheetLifecycle {
    /// 閉じることが決まった時点で呼ぶ。キーボードをシートが下がるのと同時に上げるために使う。`close(notifiesWillClose: false)`で閉じるときは呼ばない。
    var onWillClose: () -> Void = {}
    /// 閉じ終わったときに一度だけ呼ぶ。
    var onDidClose: () -> Void = {}
    /// 出し終えて、画面に現れたときに呼ぶ。
    var onDidAppear: () -> Void = {}
    /// 閉じることが決まったあと。
    private(set) var isClosing = false
    /// 閉じた知らせが来ないまま消えた。キーボードを戻した直後に閉じ終わりを知らせるので、投稿欄はキーボードの高さの知らせを待ってからバーを外す。
    private(set) var disappearedWithoutDismissCallback = false

    private let controller: UIViewController
    private let name: String
    private let logger = SciaLog.logger(category: "compose")
    private var hasNotifiedWillClose = false
    private var hasClosed = false
    /// 一度でもウィンドウに入った。前のシートが閉じ終わるのを待つ間は、UIKitが出すのを遅らせ、まだ入っていない。
    private var hasAppeared = false
    /// 出る前に閉じるよう頼まれた。出し終えたところで閉じる。出る動きの途中で閉じると、UIKitは閉じずに捨てるため。
    private var closesWhenShown = false

    /// - Parameter name: ログに出す名前。
    init(controller: UIViewController, name: String) {
        self.controller = controller
        self.name = name
        let observer = WindowObserverView()
        observer.onWindowChange = { [weak self] inWindow in self?.windowDidChange(inWindow: inWindow) }
        controller.view.addSubview(observer)
    }

    /// 出しているか、出すのを待っている。閉じ終わったあとはfalse。
    var isPresentedOrPending: Bool {
        guard !hasClosed else { return false }
        return controller.presentingViewController != nil || !hasAppeared
    }

    /// 前のシートが閉じ終わるのを待つ間は、UIKitが出すのを遅らせ、閉じ終わってから出す。
    func present(from host: UIViewController) {
        host.present(controller, animated: true) { [weak self] in self?.presentationDidFinish() }
    }

    /// プログラムから閉じる。`notifiesWillClose`なら、閉じることが決まった知らせ（キーボードを戻す）を出す。
    /// もう消えていれば、その場で閉じ終わりを知らせる。出し終えていなければ、出し終えたところで閉じる。
    func close(notifiesWillClose: Bool) {
        guard !hasClosed else { return }
        if notifiesWillClose {
            notifyWillClose()
        } else {
            isClosing = true
            // キーボードを戻さずに閉じる（ほかのシートへ切り替えるなど）と決めたあとに、スワイプで閉じ始めた知らせが遅れて届いても、キーボードを戻さない。
            // 戻すと、入力欄が書き始めたことになって、待っている次のシートを取りやめるか、出した次のシートを閉じてしまう。
            hasNotifiedWillClose = true
        }
        if controller.presentingViewController == nil, hasAppeared {
            logger.info("\(self.name, privacy: .public): close requested after it disappeared")
            finishClose()
            return
        }
        if controller.presentingViewController == nil || controller.isBeingPresented {
            logger.info("\(self.name, privacy: .public): close requested before it was shown, closing when shown")
            closesWhenShown = true
            return
        }
        // プログラムから閉じたときは`presentationControllerDidDismiss`が呼ばれないので、閉じ終わりをここでも知らせる。
        controller.dismiss(animated: true) { [weak self] in self?.finishClose() }
    }

    /// スワイプして閉じるとき、閉じ終わるのを待たず、指を離して閉じることが決まった時点で知らせる。
    /// 閉じ終わってからキーボードを出すと、一拍遅れて上がってくる。
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard let coordinator = presentationController.presentedViewController.transitionCoordinator else { return }
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard !context.isCancelled else { return }
            self?.notifyWillClose()
        }
    }

    /// 下へスワイプして閉じたときと、出した側から`dismissPresentedScreens`でまとめて閉じたとき。
    func presentationControllerDidDismiss() {
        finishClose()
    }

    private func notifyWillClose() {
        isClosing = true
        guard !hasNotifiedWillClose else { return }
        hasNotifiedWillClose = true
        logger.info("\(self.name, privacy: .public): will close")
        onWillClose()
    }

    private func finishClose() {
        guard !hasClosed else { return }
        hasClosed = true
        isClosing = true
        onDidClose()
    }

    private func presentationDidFinish() {
        guard !hasClosed, controller.presentingViewController != nil else { return }
        if closesWhenShown {
            closesWhenShown = false
            controller.dismiss(animated: true) { [weak self] in self?.finishClose() }
        } else {
            onDidAppear()
        }
    }

    private func windowDidChange(inWindow: Bool) {
        if inWindow {
            hasAppeared = true
            return
        }
        // 上に別の画面を重ねただけならまだ出しているので、出している画面がなくなったかを見て決める。
        // 外れるのは閉じる動きを終える処理の中で、出している画面との関係が切れるのはその後なので、次の順番に回して見る。
        DispatchQueue.main.async { [weak self] in
            guard let self, !hasClosed, controller.presentingViewController == nil else { return }
            logger.info("\(self.name, privacy: .public): left window without dismiss callback (closing=\(self.isClosing))")
            disappearedWithoutDismissCallback = true
            // 下へスワイプして閉じたときと同じく、書いていた入力欄にキーボードを戻す。ほかのシートへ切り替えるために閉じていたなら、戻さない。
            if !isClosing {
                notifyWillClose()
            }
            finishClose()
        }
    }
}

/// ウィンドウに入ったことと外れたことを知らせる、大きさのないビュー。
private final class WindowObserverView: UIView {
    var onWindowChange: (_ inWindow: Bool) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange(window != nil)
    }
}
