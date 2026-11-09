import UIKit

/// 共有で投稿欄に入れるときに、閉じずに残す画面。
/// タイムラインの上に重ねた画面は、既定では閉じて投稿欄を見せる。閉じると使う人が選ばずに失うものがある画面と、自分で投稿欄を見せる画面だけが、これで残る。
/// 書きかけがあって`isModalInPresentation`を立てている画面は、付けなくても残る。下へのスワイプで閉じさせないのと同じ理由なので、同じ印で見分ける。
protocol StaysForSharedContent: UIViewController {}

/// 確認のアラートとアクションシートは、選んでいる途中の選択肢を失う。
extension UIAlertController: StaysForSharedContent {}

/// アプリ内のSafariは、投稿欄で書き始めると自分で伏せた高さまで下がって投稿欄を見せる（`InAppBrowser.lowerForCompose()`）。閉じると読んでいたページを失う。
extension InAppBrowserSheet: StaysForSharedContent {}

/// 重ねた画面をまとめて閉じるときに、出した側からまとめて閉じさせず、自分の閉じ方で閉じる画面。
/// 下の画面からまとめて閉じられると閉じる動きを通らず、閉じ終えた知らせ（`MediaViewerController.onCloseFinish`）を待つ側が待ち続けるため。
protocol ClosesItself: UIViewController {
    /// 自分と、上に重ねた画面を閉じる。画面の重なりから外れたら`dismissed`を呼ぶ。
    func closeItself(dismissed: @escaping () -> Void)
}

extension MediaViewerController: ClosesItself {}

extension UIViewController {
    /// 共有で投稿欄に入れるときに、投稿欄を隠している画面を閉じる。閉じ終えたら`completion`を呼ぶ。
    /// 残す画面（`StaysForSharedContent`）に当たったら、その上までで止める。
    func closeScreensForSharedContent(completion: @escaping () -> Void) {
        closeScreens(stoppingAt: { $0.staysForSharedContent }, completion: completion)
    }

    /// 上に重ねた画面のどこかに、確認のアラートがあるか。
    var isShowingAlert: Bool {
        var current = self
        while let presented = current.presentedViewController {
            if presented is UIAlertController { return true }
            current = presented
        }
        return false
    }

    /// 上に重ねた画面を、手前から順にすべて閉じる。閉じ終えたら`completion`を呼ぶ。
    func closeAllScreens(completion: @escaping () -> Void) {
        closeScreens(stoppingAt: { _ in false }, completion: completion)
    }

    /// アプリ内のSafariのシートより手前に重ねた画面を閉じる。閉じ終えたら`completion`を呼ぶ。
    func closeScreensAboveInAppBrowser(completion: @escaping () -> Void) {
        closeScreens(stoppingAt: { $0 is InAppBrowserSheet }, completion: completion)
    }

    /// 上に重ねた画面を手前から順に閉じ、`stays`が残すと決めた画面に当たったら、その上までで止める。閉じ終えたら`completion`を呼ぶ。
    /// 自分で閉じる画面（`ClosesItself`）があれば、先にその閉じ方で閉じてから、下の画面を閉じる。
    /// ほかの画面は、出した側から`dismissPresentedScreens`でまとめて閉じる。
    private func closeScreens(stoppingAt stays: @escaping (UIViewController) -> Bool, completion: @escaping () -> Void) {
        var chain: [UIViewController] = []
        var current = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            chain.append(presented)
            current = presented
        }
        let closable = Array(chain.reversed().prefix { !stays($0) })
        guard let lowest = closable.last else {
            completion()
            return
        }
        // 入力欄で打っている途中なら、打ち終えてから閉じる。設定の数値の欄は、入力を終えたときに打った値にする。
        for screen in closable {
            screen.viewIfLoaded?.endEditing(true)
        }
        if let closesItself = closable.last(where: { $0 is any ClosesItself }) as? any ClosesItself {
            closesItself.closeItself { [weak self] in
                guard let self, closesItself !== lowest else {
                    completion()
                    return
                }
                closeScreens(stoppingAt: stays, completion: completion)
            }
        } else if let presenter = lowest.presentingViewController {
            presenter.dismissPresentedScreens(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    /// 共有で投稿欄に入れるときに残す画面か。ナビゲーションに載せた画面のように、中の画面が残すと決めていれば残す。
    private var staysForSharedContent: Bool {
        self is any StaysForSharedContent || isModalInPresentation || children.contains { $0.staysForSharedContent }
    }
}
