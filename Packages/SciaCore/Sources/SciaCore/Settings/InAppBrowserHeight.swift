/// アプリ内のSafariを中くらいの高さで開くときのシートの高さ。使う人が、ホームの上でシートの上端を引いて決める。
/// 窓の安全領域の中の高さから、上に空ける長さを引いて決める。割合でなく長さで決めるのは、端末の大きさによらず上に見える量を揃えるため。
/// 最初から全画面で開くかは、別の設定（`AppSettings.opensInAppBrowserFullScreen`）で決める。全画面で開いても、つまみで下げるとこの高さで止まる。
public struct InAppBrowserHeight: Hashable, Sendable {
    /// 上に空ける長さ（pt、安全領域の中）。`step`の刻みに揃えてある。
    public let spaceAbove: Double

    /// 上に空ける長さの刻み。シートの段をこの刻みで並べ、引いた位置にいちばん近い段で止める。
    public static let step: Double = 4
    /// 上に最新の投稿が1件見えるくらい。
    public static let standard = InAppBrowserHeight(spaceAbove: 160)
    /// 決められる上に空ける長さの短いほうの端。刻み2つぶん。
    /// 0ptと4ptの段は全画面とほぼ同じ高さになり、高さを決めるシートにその段を並べると、iOS 26のシミュレーターでは、
    /// シートが浮いた形から画面の下と左右の端に付いた形に変わり、アプリ内のSafariのシートと見え方が合わなくなったため。
    public static let minimumSpace: Double = step * 2

    /// 上に空ける長さを刻みに揃える。短いほうの端より短い長さは端に寄せる。
    /// 数でない値（NaNや無限大）は寄せられないので、読むところで弾いてから渡す（`AppSettings`）。
    public init(spaceAbove: Double) {
        self.spaceAbove = max((spaceAbove / Self.step).rounded() * Self.step, Self.minimumSpace)
    }

    /// 設定に出す今の値。
    public var title: String {
        "\(Int(spaceAbove))pt"
    }

    /// シートの高さ（pt、下の安全領域を除く）。
    /// - Parameters:
    ///   - available: 窓の高さから上下の安全領域を除いた高さ。
    ///     シートの段の計算にUIKitが渡す最大の高さは使わない。アプリ内のSafariのシートにだけ、同じ窓でも10pt少ない値が渡り、
    ///     高さを決めるシートと本物で上端の位置がずれたため（iOS 26のシミュレーターで、どちらも同じ窓と安全領域で確かめた）。
    ///   - minimum: 伏せた高さ（投稿欄で書いている間にシートを下げる高さ）。ほかの端末で決めた長さが、この窓では引ききれないとき（高さの低い窓）は、ここで止める。
    public func sheetHeight(available: Double, minimum: Double) -> Double {
        max(available - spaceAbove, minimum)
    }

    /// この窓で決められる上に空ける長さ。短いほうの端から、シートが伏せた高さになるところまで、刻みごとに並べる。
    public static func selectableSpaces(available: Double, minimum: Double) -> [Double] {
        guard available - minimum >= minimumSpace else { return [] }
        return Array(stride(from: minimumSpace, through: available - minimum, by: step))
    }

    /// この窓で決められる範囲に寄せる。ほかの端末で決めた長さが、この窓では引ききれないときに使う。
    public func clamped(available: Double, minimum: Double) -> InAppBrowserHeight {
        InAppBrowserHeight(spaceAbove: min(spaceAbove, Self.selectableSpaces(available: available, minimum: minimum).last ?? Self.minimumSpace))
    }
}
