public import CoreGraphics

/// 一覧のどの行を、表示中として既読の報告（`FeedTimelineModel.markRead(_:)`など）に渡すかを決める。
/// 未読の数とサーバーに保存する既読位置がこれで決まるので、iOSとmacOSで同じ決まりを使う。
public enum ReadVisibility {
    /// 報告するか。見ていない間（ほかのタブにいる、添付ファイルのビューアやアプリ内のSafariで覆っている）は報告しない。
    /// 窓が前面にない間は、使う人がスクロールしたときだけ報告する。
    /// - Parameters:
    ///   - isShown: 一覧が窓に出ていて、ほかの画面で覆われていない。
    ///   - isWindowActive: 窓が前面にある。
    ///   - byUser: 使う人のスクロールで表示が変わった。
    public static func shouldReport(isShown: Bool, isWindowActive: Bool, byUser: Bool) -> Bool {
        isShown && (isWindowActive || byUser)
    }

    /// 行の高さの半分以上が表示領域に入っているか。行が表示領域より高ければ、表示領域の高さの半分以上を占めていれば入っているとする。
    /// - Parameters:
    ///   - frame: 行の枠。
    ///   - visibleRect: 表示領域。ナビゲーションバーなどに隠れている部分は除いて渡す。
    public static func isVisible(_ frame: CGRect, in visibleRect: CGRect) -> Bool {
        let visibleHeight = frame.intersection(visibleRect).height
        return visibleHeight >= min(frame.height, visibleRect.height) / 2
    }

    /// `rows`のうち、`isVisible(_:in:)`で入っている行のIDを、渡した順に返す。
    public static func visibleIDs<ID>(of rows: [(id: ID, frame: CGRect)], in visibleRect: CGRect) -> [ID] {
        rows.filter { isVisible($0.frame, in: visibleRect) }.map(\.id)
    }
}
