import SciaCore
import SwiftUI
import UIKit

/// 投稿欄の＋の「カスタマイズ」から重ねる、ボタンの並びを変える画面。設定の「投稿欄のボタン」と同じ画面を、閉じるボタン付きで出す。
/// 「完了」でも、下へスワイプしても、出した側から閉じられても、閉じたら`onClose`を1回呼ぶ。
final class ComposeToolLayoutSheet: UIHostingController<ComposeToolLayoutSheet.Content> {
    private let onClose: () -> Void
    private var hasClosed = false
    /// 自分の`dismiss`で閉じている。`viewDidDisappear`は`dismiss`の完了より先に呼ばれるので、そこで知らせると、`completion`より先に閉じたことを知らせてしまう。
    private var isDismissingItself = false

    struct Content: View {
        @Bindable var settings: AppSettings
        let dismiss: () -> Void

        var body: some View {
            NavigationStack {
                MenuLayoutSettingsView(title: "投稿欄のボタン", layout: $settings.composeToolLayout)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了", action: dismiss)
                        }
                    }
            }
        }
    }

    init(settings: AppSettings, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // 閉じる処理は自分を参照するため、作り終えてから入れ直す。
        super.init(rootView: Content(settings: settings, dismiss: {}))
        rootView = Content(settings: settings) { [weak self] in self?.dismiss(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
    }

    /// 「完了」やコードから閉じたとき。閉じ終わってから知らせる。
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        isDismissingItself = true
        super.dismiss(animated: flag) {
            completion?()
            self.notifyClosed()
        }
    }

    /// 出した側の画面からまとめて閉じられたとき（共有で投稿欄に入れるときや、デバッグのリセットなど）。自分の`dismiss`も下へのスワイプの知らせも通らないので、消えたところで知らせる。
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

extension ComposeToolLayoutSheet: UIAdaptivePresentationControllerDelegate {
    /// 下へスワイプして閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notifyClosed()
    }
}
