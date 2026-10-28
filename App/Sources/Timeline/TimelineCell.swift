import SciaCore
import UIKit

/// 一覧の行。スクロールの間に、行の大きさを測るのにかかった時間を、行の種類ごとに`FrameWork`へ渡す。
/// 行の大きさは、中身のビューではなくセルが測られるため、セルで測る。
final class TimelineCell: UICollectionViewListCell {
    /// 測った時間に付ける、行の種類の名前。
    var workName = "row"
    /// 出している行。別の行を出し始めたかを見分ける。
    var itemID: TimelineViewController.ItemID?

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        FrameWork.measure("\(workName).sizing") { super.preferredLayoutAttributesFitting(layoutAttributes) }
    }
}

extension TimelineEntry {
    /// `FrameWork`で測った時間に付ける、行の種類の名前。
    var workName: String {
        switch self {
        case .status: "status"
        case .pinned: "pinned"
        case .gap: "gap"
        case .notification: "notification"
        case .unreadable: "unreadable"
        case .account: "account"
        }
    }
}
