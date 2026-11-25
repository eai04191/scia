import Testing
import UIKit

/// テストで、画面に出ている見え方のままビューを画像に描く。テストの中で`drawHierarchy`を呼ぶのは、これだけにする。
/// `drawHierarchy(afterScreenUpdates: true)`は、描く範囲によらず1回に20〜40ミリ秒かかる。毎コマ描くと1つのテストが数秒延びるので、1つの描き手で描ける回数を限り、超えたら落とす。
/// 比べるコマだけを描く。描き手はテストごとに1つ作る。
@MainActor
final class HierarchyDrawer {
    nonisolated static let limit = 4

    private var count = 0

    func image(of view: UIView, scale: CGFloat? = nil, sourceLocation: SourceLocation = #_sourceLocation) -> UIImage {
        count += 1
        if count == Self.limit + 1 {
            Issue.record("1つのテストでdrawHierarchyを\(Self.limit)回より多く呼びました。1回に20〜40ミリ秒かかるので、比べるコマだけを描いてください", sourceLocation: sourceLocation)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale ?? view.window?.screen.scale ?? format.scale
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }
}
