import SciaCore
import UIKit

extension AppSettings {
    /// 一覧の行（投稿、通知、アカウント）の上下左右の余白。どの行も同じ余白にそろえる。
    var rowMargins: NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: value(of: AppearanceCatalog.rowPaddingTop),
            leading: value(of: AppearanceCatalog.rowPaddingLeading),
            bottom: value(of: AppearanceCatalog.rowPaddingBottom),
            trailing: value(of: AppearanceCatalog.rowPaddingTrailing)
        )
    }
}
