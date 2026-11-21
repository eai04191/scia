import UIKit

extension UITextSmartInsertDeleteType {
    /// UIKitの入力欄のスマート挿入。英字の後ろに「─」を貼ると、「abc ─」のように前に空白を足す。
    /// iOSでは設定の「一般 > キーボード > スマート句読点」に従い、オフにすると足さないので、既定のままにする。
    /// Macで動くときは、Macのスマート引用符とスマートダッシュを切っても空白が付いたため切る。Macにこのキーボード設定が届かないことは、直接は確かめていない。
    static var offOnMac: UITextSmartInsertDeleteType {
        ProcessInfo.processInfo.isiOSAppOnMac ? .no : .default
    }
}
