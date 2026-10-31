import SafariServices
import UIKit

/// 共有で投稿欄に入れるときに、閉じずに残す画面。
/// 一覧の上に重ねた画面は、既定では閉じて投稿欄を見せる。閉じると使う人が選ばずに失うものがある画面と、自分で投稿欄を見せる画面だけが、これで残る。
/// 書きかけがあって`isModalInPresentation`を立てている画面は、付けなくても残る。下へのスワイプで閉じさせないのと同じ理由なので、同じ印で見分ける。
protocol StaysForSharedContent: UIViewController {}

/// 確認のアラートとアクションシートは、選んでいる途中の選択肢を失う。
extension UIAlertController: StaysForSharedContent {}

/// アプリ内のSafariは、投稿欄で書き始めると自分で伏せた高さまで下がって投稿欄を見せる（`InAppBrowser.lowerForCompose()`）。閉じると読んでいたページを失う。
extension SFSafariViewController: StaysForSharedContent {}

/// 共有で投稿欄に入れるときに、出した側からまとめて閉じさせず、自分の閉じ方で閉じる画面。
/// 下の画面からまとめて閉じられると閉じる動きを通らず、閉じ終えた知らせ（`MediaViewerController.onCloseFinish`）を待つ側が待ち続けるため。
protocol ClosesItselfForSharedContent: UIViewController {
    /// 自分と、上に重ねた画面を閉じる。画面の重なりから外れたら`dismissed`を呼ぶ。
    func closeForSharedContent(dismissed: @escaping () -> Void)
}

extension MediaViewerController: ClosesItselfForSharedContent {}

extension UIViewController {
    /// 共有で投稿欄に入れるときに、投稿欄を隠している画面を閉じる。閉じ終えたら`completion`を呼ぶ。
    /// 手前から順に閉じられる画面だけを閉じ、残す画面（`StaysForSharedContent`）に当たったら、その上までで止める。
    /// 自分で閉じる画面（`ClosesItselfForSharedContent`）があれば、先にその閉じ方で閉じてから、下の画面を閉じる。
    /// ほかの画面は、出した側からまとめて閉じ、閉じ終えたら下へスワイプして閉じたときと同じ知らせ（`presentationControllerDidDismiss`）を送る。
    /// 出した側から閉じると、UIKitはこの知らせを送らず、画面の`dismiss`も通らない。シートはどれもスワイプで閉じたときの後始末をこの知らせで行うので、
    /// 画面ごとにまとめて閉じられたときの扱いを足さなくても、閉じたことになる。
    func closeScreensForSharedContent(completion: @escaping () -> Void) {
        var chain: [UIViewController] = []
        var current = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            chain.append(presented)
            current = presented
        }
        let closable = Array(chain.reversed().prefix { !$0.staysForSharedContent })
        guard let lowest = closable.last else {
            completion()
            return
        }
        // 入力欄で打っている途中なら、打ち終えてから閉じる。設定の数値の欄は、入力を終えたときに打った値にする。
        for screen in closable {
            screen.viewIfLoaded?.endEditing(true)
        }
        if let closesItself = closable.last(where: { $0 is any ClosesItselfForSharedContent }) as? any ClosesItselfForSharedContent {
            closesItself.closeForSharedContent { [weak self] in
                guard let self, closesItself !== lowest else {
                    completion()
                    return
                }
                closeScreensForSharedContent(completion: completion)
            }
        } else if let presenter = lowest.presentingViewController {
            let presentations = closable.map(\.presentationController)
            presenter.dismiss(animated: true) {
                for case let presentation? in presentations {
                    presentation.delegate?.presentationControllerDidDismiss?(presentation)
                }
                completion()
            }
        } else {
            completion()
        }
    }

    /// 共有で投稿欄に入れるときに残す画面か。ナビゲーションに載せた画面のように、中の画面が残すと決めていれば残す。
    private var staysForSharedContent: Bool {
        self is any StaysForSharedContent || isModalInPresentation || children.contains { $0.staysForSharedContent }
    }
}
