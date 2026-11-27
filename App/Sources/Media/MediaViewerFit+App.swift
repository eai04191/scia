import SciaCore
import UIKit

extension MediaViewerFit {
    /// 画面に収めるときに避ける、画面を覆う領域。`view`の座標で、`view`は画面と同じ位置と大きさのビューにする。
    /// iOS 27.1からは、OSの予約領域（アイランド、カメラ、ステータスバーなど）。
    @MainActor
    static func reservedRegions(in view: UIView) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return view.reservedRegions(kind: .occlusion).map(\.frame)
        }
        let edges = edgesWithoutReservedRegions(in: view.window)
        let size = view.bounds.size
        return [
            CGRect(x: 0, y: 0, width: size.width, height: edges.top),
            CGRect(x: 0, y: 0, width: edges.left, height: size.height),
            CGRect(x: size.width - edges.right, y: 0, width: edges.right, height: size.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// 予約領域のAPIがないiOSで避ける幅。ホームボタンのないiPhoneでは、アイランドかノッチのある辺を避ける。
    /// アイランドの位置を測ってある機種（`IslandModel`）では、アイランドの端までを避ける。ほかの機種では、その辺のセーフエリアの幅を避ける。
    /// ホームインジケータの辺は避けない。
    /// 切り欠きのない機種（iPhone SE、iPad）では避けない。セーフエリアの上端はステータスバーの分で、隠すと縮むため、使うと画面の部品を出し入れするたびに画像が動く。
    /// ホームボタンのないiPhoneは、どれもアイランドかノッチがあり、ステータスバーを隠してもセーフエリアは変わらない。
    @MainActor
    private static func edgesWithoutReservedRegions(in window: UIWindow?) -> Edges {
        guard let window, window.traitCollection.userInterfaceIdiom == .phone else { return .zero }
        let insets = window.safeAreaInsets
        guard insets.bottom > 0 else { return .zero }
        if let islandEdge = islandEdge(in: window) {
            switch window.windowScene?.effectiveGeometry.interfaceOrientation {
            case .portrait: return Edges(top: islandEdge)
            // 画面の上端が左にある向き。
            case .landscapeRight: return Edges(left: islandEdge)
            case .landscapeLeft: return Edges(right: islandEdge)
            default: break
            }
        }
        return Edges(top: insets.top, left: insets.left, right: insets.right)
    }

    /// 縦向きの画面の上端から、アイランドの下端までの長さ。アイランドの位置を測っていない機種ではnil。
    @MainActor
    private static func islandEdge(in window: UIWindow) -> CGFloat? {
        guard let model = IslandModel.table[DeviceModel.identifier],
              case let .island(rect, _) = model.scaled(toWidth: min(window.bounds.width, window.bounds.height))
        else { return nil }
        return rect.maxY
    }
}

/// 画面に収めるときに避ける領域を読み、変わったら知らせる。画面と同じ位置と大きさに置く。
/// 予約領域は`updateConstraints()`で読む。UIKitはそこで読んだ予約領域を保持し、変わると呼び直すため。
final class MediaViewerReservedRegionsView: UIView {
    private(set) var regions: [CGRect] = []
    var onChange: (([CGRect]) -> Void)?

    override class var requiresConstraintBasedLayout: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConstraints() {
        refresh()
        super.updateConstraints()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsUpdateConstraints()
        refresh()
    }

    func refresh() {
        let regions = MediaViewerFit.reservedRegions(in: self)
        guard regions != self.regions else { return }
        self.regions = regions
        onChange?(regions)
    }
}

extension UIEdgeInsets {
    init(_ edges: MediaViewerFit.Edges) {
        self.init(top: edges.top, left: edges.left, bottom: edges.bottom, right: edges.right)
    }
}
