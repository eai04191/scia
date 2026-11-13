import SciaCore
import UIKit

extension AppSettings {
    /// タイムラインの行（投稿、通知、アカウント）の上下左右の余白。どの行も同じ余白にそろえる。
    var rowMargins: NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: value(of: AppearanceCatalog.rowPaddingTop),
            leading: value(of: AppearanceCatalog.rowPaddingLeading),
            bottom: value(of: AppearanceCatalog.rowPaddingBottom),
            trailing: value(of: AppearanceCatalog.rowPaddingTrailing)
        )
    }

    /// 行の文字の列の左端。アイコンの右。
    var textColumnLeading: CGFloat {
        rowMargins.leading + value(of: AppearanceCatalog.avatarSize) + value(of: AppearanceCatalog.avatarSpacing)
    }

    /// 投稿の行の区切り線の左端。本文の左端から引く。決まりはdocs/post-header-layout.mdの「区切り線」にある。
    var postSeparatorLeading: CGFloat {
        appearance.wrapsBelowAvatar ? rowMargins.leading : textColumnLeading
    }
}
