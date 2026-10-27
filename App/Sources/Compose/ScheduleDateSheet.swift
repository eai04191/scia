import SciaCore
import UIKit

/// 予約の日時を選ぶシート。投稿欄の予約の行と、予約の一覧の「日時を変える」から出す。決まりはdocs/compose.mdの「予約投稿」にある。
/// 日時は標準の`UIDatePicker`のカレンダーと時刻で選ぶ。選べるのは、サーバーが受け付ける今から5分より後だけ。
/// 決めても、キャンセルしても、下へスワイプしても、出した側から閉じられても、閉じたら`onClose`を1回呼ぶ。決めたときは、閉じ終えてから、`onClose`の前に`onConfirm`を呼ぶ。
final class ScheduleDateSheet: UINavigationController {
    private let picker = UIDatePicker()
    private let onConfirm: (Date) -> Void
    private let onClose: () -> Void
    private var hasClosed = false
    /// 自分の`dismiss`で閉じている。`viewDidDisappear`は`dismiss`の完了より先に呼ばれるので、そこで知らせると、決めたことより先に閉じたことを知らせてしまう。
    private var isDismissingItself = false

    /// - Parameters:
    ///   - title: 見出し。
    ///   - confirmTitle: 決めるボタンの文字。
    init(title: String, date: Date, minimumDate: Date, confirmTitle: String, onConfirm: @escaping (Date) -> Void, onClose: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onClose = onClose
        let content = UIViewController()
        super.init(rootViewController: content)
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .inline
        picker.minimumDate = minimumDate
        picker.date = max(date, minimumDate)
        picker.translatesAutoresizingMaskIntoConstraints = false
        content.view.backgroundColor = .systemBackground
        content.view.addSubview(picker)
        let margins = content.view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            picker.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
        ])
        content.title = title
        content.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let confirm = UIBarButtonItem(title: confirmTitle, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let date = picker.date
            // 閉じ終えてから知らせる。決めた日時を受け付けられないときのアラートを、閉じていくシートの上に出さないため。
            dismiss(animated: true) { onConfirm(date) }
        })
        confirm.style = .prominent
        content.navigationItem.rightBarButtonItem = confirm
        // カレンダーと時刻が収まる高さで出す。画面が低ければ、上まで広げる。
        sheetPresentationController?.detents = [.custom { [weak self] context in
            guard let self else { return context.maximumDetentValue }
            let fitting = picker.systemLayoutSizeFitting(CGSize(width: context.containerTraitCollection.horizontalSizeClass == .regular ? 400 : UIView.layoutFittingCompressedSize.width, height: 0)).height
            return min(fitting + navigationBar.bounds.height + 24, context.maximumDetentValue)
        }]
        sheetPresentationController?.prefersGrabberVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
    }

    /// 決めたとき、キャンセルしたとき、コードから閉じたとき。閉じ終わってから知らせる。
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        isDismissingItself = true
        // 閉じ終わるまでの間だけ自分を持つ。弱く持つと、閉じたあとに出していた画面が手放していて、知らせられないことがある。
        super.dismiss(animated: flag) {
            completion?()
            self.notifyClosed()
        }
    }

    /// 出した側の画面からまとめて閉じられたとき（デバッグのリセットなど）。自分の`dismiss`も下へのスワイプの知らせも通らないので、消えたところで知らせる。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isDismissingItself, isBeingDismissed || presentingViewController == nil {
            notifyClosed()
        }
    }

    private func notifyClosed() {
        guard !hasClosed else { return }
        hasClosed = true
        onClose()
    }
}

extension ScheduleDateSheet: UIAdaptivePresentationControllerDelegate {
    /// 下へスワイプして閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notifyClosed()
    }
}
