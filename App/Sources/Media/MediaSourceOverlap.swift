import UIKit

/// 開閉の起点の上に重なっているビュー（ヘッダー画像にかかるアイコンなど）の複製。画像の複製のさらに手前に置く。
///
/// 画像の複製は一覧より手前に描くため、そのままでは起点に重なっているビューまで覆い、開き始めに消え、閉じ終わりに急に現れて見える。
/// 複製を重ねて、起点の大きさの近くでは元のビューが残って見えるようにし、サムネイルに重ねた表示と同じ濃さで出し入れする。
/// 一覧のバーの手前に描かないよう、起点を含む一覧のバーに隠れない範囲で切り抜く。
/// 閉じる途中に一覧をスクロールされても元のビューと重なるよう、起点が動いた分だけ複製も動かす。
@MainActor
final class MediaSourceOverlap {
    /// 切り抜く範囲の枠。複製を載せる層に置く。
    let view = UIView()
    /// 複製を並べる層。起点が動いた分だけずらす。
    private let content = UIView()
    private let window: UIWindow
    /// 複製を作ったときの起点の枠。ウィンドウ座標。
    private let sourceFrame: CGRect

    /// 起点に重なっているビューが見えていなければnil。
    init?(source: any MediaViewerSource, in window: UIWindow) {
        let visibleRect = MediaBarLayering.visibleRect(around: source, in: window) ?? window.bounds
        let snapshots = source.overlappingViews.compactMap { overlapping -> UIView? in
            guard overlapping.window === window, !overlapping.isHidden, overlapping.alpha > 0,
                  let snapshot = overlapping.snapshotView(afterScreenUpdates: false)
            else { return nil }
            // 回したり縮めたりしたビュー（一覧で重ねた写真）も同じ形に重なるよう、元の大きさで写し、同じ中心に置いてから同じ角度と倍率にする。
            let frame = overlapping.unrotatedFrame(in: window)
            let scale = overlapping.scale(in: window)
            snapshot.bounds.size = overlapping.bounds.size
            snapshot.center = CGPoint(x: frame.midX - visibleRect.minX, y: frame.midY - visibleRect.minY)
            snapshot.transform = CGAffineTransform(rotationAngle: overlapping.rotation(in: window)).scaledBy(x: scale, y: scale)
            return snapshot
        }
        guard !snapshots.isEmpty else { return nil }
        self.window = window
        sourceFrame = source.convert(source.bounds, to: window)
        view.frame = visibleRect
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        content.frame = view.bounds
        snapshots.forEach(content.addSubview)
        view.addSubview(content)
    }

    /// 複製を`container`の上に置き直す。`container`の座標はウィンドウと同じでなくてもよい。
    func move(to container: UIView) {
        let frame = view.superview?.convert(view.frame, to: window) ?? view.frame
        view.frame = container.convert(frame, from: window)
        container.addSubview(view)
    }

    /// 起点が複製を作ったときから動いた分だけ、複製をずらす。
    func follow(_ source: any MediaViewerSource) {
        let frame = source.convert(source.bounds, to: window)
        content.frame.origin = CGPoint(x: frame.minX - sourceFrame.minX, y: frame.minY - sourceFrame.minY)
    }
}
