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

    /// 通知と人の行の、文字の列の左端。アイコンの右。これらの行は、投稿のアイコンを出さない設定でもアイコンを出すので、設定によらずアイコンの列を取る。
    var textColumnLeading: CGFloat {
        rowMargins.leading + value(of: AppearanceCatalog.avatarSize) + value(of: AppearanceCatalog.avatarSpacing)
    }

    /// 投稿の行の左のアイコンの一辺。アイコンを出さなければ0。
    /// - Parameter appearance: 投稿を組むときの見た目の選択肢。スレッドで開いた投稿は、設定と違うことがある。
    func postAvatarSize(_ appearance: AppearanceChoices) -> CGFloat {
        appearance.showsAvatar ? value(of: AppearanceCatalog.avatarSize) : 0
    }

    /// 投稿の行の左のアイコンの列と、文字の列のあいだ。アイコンを出さなければ0。
    func postAvatarSpacing(_ appearance: AppearanceChoices) -> CGFloat {
        appearance.showsAvatar ? value(of: AppearanceCatalog.avatarSpacing) : 0
    }

    /// 投稿の行の区切り線の左端。本文の左端から引く。決まりはdocs/post-header-layout.mdの「区切り線」にある。
    var postSeparatorLeading: CGFloat {
        postSeparatorLeading(appearance)
    }

    func postSeparatorLeading(_ appearance: AppearanceChoices) -> CGFloat {
        appearance.wrapsBelowAvatar ? rowMargins.leading : rowMargins.leading + postAvatarSize(appearance) + postAvatarSpacing(appearance)
    }
}
