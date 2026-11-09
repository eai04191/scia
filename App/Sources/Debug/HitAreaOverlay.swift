import QuartzCore
import UIKit

/// 開発用。指を受けるビューの範囲を、受けるビューごとに色を変えて、すべての画面の上に重ねて出す。
/// ビューの枠をなぞらず、画面を区切った点ごとに、UIKitが指を配るのと同じ順でウィンドウの`hitTest`を呼んで調べる。
/// `point(inside:)`や`hitTest`を上書きして範囲を広げたり狭めたりした部品も、実際に指を受ける範囲で出る。
/// `hitTest`はモデルの層の位置で判定するので、アニメーションの途中は、動いている見た目ではなく行き先の位置に出る。
/// SwiftUIの部品の中は、ボタンがUIKitのビューではないため、`UIHostingController`のビュー1つの範囲として出る。
/// 親のビューに付けたジェスチャーは、指を受けた子のビューの範囲に含めて出し、どのジェスチャーが勝つかは出さない。
/// 別のプロセスが描くもの（写真のピッカー、システムのメニュー）は調べられない。
@MainActor
enum HitAreaOverlay {
    private static var windows: [ObjectIdentifier: HitAreaWindow] = [:]

    static func isShown(in scene: UIWindowScene) -> Bool {
        windows[ObjectIdentifier(scene)] != nil
    }

    /// すべてのシーンで消す。デバッグメニューがなくなると、オフにする項目もなくなるため。
    static func hideAll() {
        for window in windows.values {
            window.stop()
            window.isHidden = true
        }
        windows.removeAll()
    }

    static func setShown(_ isShown: Bool, in scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        if isShown, windows[key] == nil {
            let window = HitAreaWindow(windowScene: scene)
            window.isHidden = false
            windows[key] = window
        } else if !isShown, let window = windows.removeValue(forKey: key) {
            window.stop()
            window.isHidden = true
        }
    }
}

/// 一番手前に置き、指を受けずに下のウィンドウへ通すウィンドウ。根の画面を持たせないのは、ステータスバーの見た目と画面の向きを下のウィンドウに任せるため。
private final class HitAreaWindow: UIWindow {
    /// 調べる点の間隔（pt）。細かくするほど境目が正確になるが、`hitTest`の回数が増える。
    private static let step: CGFloat = 4
    /// 縁を細かく調べるビューの、短い辺の長さ（pt）。これ以上のビューは、区画（`HitGrid`）の角と中心で見つかる。
    private static let smallViewSize: CGFloat = 32
    /// 枠の中をすべて調べる、`hitTest`を上書きしたビューの、画面に占める広さの割合の上限。
    private static let detailedAreaRatio: CGFloat = 0.25
    /// 1フレームで調べるのに使ってよい時間の、フレームの間隔に対する割合。画面のすべてを調べるのは1フレームに収まらないため、フレームに分けて調べ、調べ終えたら描き直す。
    /// タイムラインの画面では、すべてを調べるのにシミュレーターで合わせて1秒ほどかかる。1フレームで済ませると、表示している間の操作が止まる。
    /// 割合を上げると早く描き直せるが、表示している間のスクロールが引っかかる。
    private static let frameBudgetRatio: CFTimeInterval = 0.5

    private let drawing = CALayer()
    private let labels = CALayer()
    private var displayLink: CADisplayLink?
    /// 調べている途中の結果。調べ終えるまで、前に調べた結果を出しておく。
    private var pending: HitGrid?
    private var shown: HitAreaSignature?
    private var rendering: Task<Void, Never>?

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 100
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.addSublayer(drawing)
        layer.addSublayer(labels)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        rendering?.cancel()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let deadline = CACurrentMediaTime() + (link.targetTimestamp - link.timestamp) * Self.frameBudgetRatio
        guard var grid = pending ?? makeGrid() else { return }
        if grid.advance(shouldPause: { CACurrentMediaTime() >= deadline }) {
            pending = nil
            show(grid)
        } else {
            pending = grid
        }
    }

    private func makeGrid() -> HitGrid? {
        let targets = targetWindows()
        let step = Self.step
        let columns = Int((bounds.width / step).rounded(.up))
        let rows = Int((bounds.height / step).rounded(.up))
        guard columns > 0, rows > 0 else { return nil }
        return HitGrid(columns: columns, rows: rows, detail: detailCells(in: targets, columns: columns, rows: rows)) { [weak self] column, row in
            self?.hitView(at: CGPoint(x: (CGFloat(column) + 0.5) * step, y: (CGFloat(row) + 0.5) * step), in: targets)
        }
    }

    /// 前と同じ結果なら描き直さない。描き直すたびに画面が動いたことになり、`Tools/sim.sh`が画面が止まるのを待ち続けるため。
    /// 点ごとに受けるビューが同じでも、ビューが点の間で動いたときや、画面の大きさと倍率が変わったときは描き直す。境目を枠の縁で描くため。
    private func show(_ grid: HitGrid) {
        let map = HitAreaMap(views: grid.views, columns: grid.columns, rows: grid.rows, step: Self.step, in: self, windows: targetWindows())
        let scale = traitCollection.displayScale
        let signature = HitAreaSignature(views: grid.views, frames: map.frames, size: bounds.size, scale: scale)
        guard signature != shown else { return }
        shown = signature
        let raster = map.raster(fill: { Self.premultiplied(for: $0, alpha: 0.22) }, line: { Self.premultiplied(for: $0, alpha: 0.9) })
        let labelSpecs = map.distinct.enumerated().map { index, view in
            HitAreaLabel(view: Int32(index), name: Self.typeName(of: view), color: Self.color(for: view, alpha: 0.85))
        }
        let size = bounds.size
        rendering?.cancel()
        // 画素ごとの計算と名前の画像は、タイムラインの画面で合わせて0.5〜0.8秒ほどかかるので、メインスレッドを止めないよう、ビューに触らない数値だけにしてから別のスレッドで行う。
        rendering = Task { [weak self] in
            let (image, labelImage) = await Task.detached {
                (raster.render(size: size, scale: scale), raster.renderLabels(labelSpecs, size: size, scale: scale))
            }.value
            guard let self, !Task.isCancelled else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            drawing.frame = CGRect(origin: .zero, size: image.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? size)
            drawing.contentsScale = scale
            drawing.contents = image
            labels.frame = CGRect(origin: .zero, size: size)
            labels.contentsScale = scale
            labels.contents = labelImage
            CATransaction.commit()
        }
    }

    /// 区画の角と中心だけでは見落とすおそれがあり、細かく調べる点。
    /// アプリのコードで`hitTest`か`point(inside:)`を上書きしたビューは、枠の中の一部だけで受けることがあるので（本文のうちリンクの文字の上だけで受ける`LinkHitArea`など）、枠の中をすべて調べる。
    /// ただし、画面の大部分を覆うものは除く。通知のチップを重ねる`NoticeOverlay`のように、画面全体を覆って子のビューにだけ指を通すものまで含めると、画面のすべての点を調べることになるため。子のビューは別に調べる。
    /// そのほかの指を受けそうな小さなビュー（コントロール、ジェスチャーの付いたビュー）は、区画より小さなボタンを見落とさないよう、縁を調べる。
    /// 大きなビューの縁まで含めると、タイムラインの画面では、ほぼすべての区画を細かく調べることになり、角と中心で見つかるため外す。
    private func detailCells(in targets: [UIWindow], columns: Int, rows: Int) -> [Bool] {
        var detail = [Bool](repeating: false, count: columns * rows)
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return }
            let rect = view.convert(view.bounds, to: self).intersection(bounds)
            if !rect.isNull, !rect.isEmpty {
                let minX = max(Int(rect.minX / Self.step), 0), maxX = min(Int((rect.maxX - 0.01) / Self.step), columns - 1)
                let minY = max(Int(rect.minY / Self.step), 0), maxY = min(Int((rect.maxY - 0.01) / Self.step), rows - 1)
                if minX <= maxX, minY <= maxY {
                    if rect.width * rect.height < bounds.width * bounds.height * Self.detailedAreaRatio, overridesHitTesting(type(of: view)) {
                        for row in minY...maxY {
                            for column in minX...maxX {
                                detail[row * columns + column] = true
                            }
                        }
                    } else if min(rect.width, rect.height) < Self.smallViewSize,
                              view is UIControl || view.gestureRecognizers?.isEmpty == false {
                        for column in minX...maxX {
                            detail[minY * columns + column] = true
                            detail[maxY * columns + column] = true
                        }
                        for row in minY...maxY {
                            detail[row * columns + minX] = true
                            detail[row * columns + maxX] = true
                        }
                    }
                }
            }
            for subview in view.subviews {
                visit(subview)
            }
        }
        for window in targets {
            visit(window)
        }
        return detail
    }

    /// 型ごとに覚えた、アプリのコードで`hitTest`か`point(inside:)`を上書きしているか。
    private var overrides: [ObjectIdentifier: Bool] = [:]

    /// アプリのコードで上書きしているか。UIKitの部品（`UIScrollView`や`UIControl`など）も上書きしているが、枠の中をすべて受けるので含めない。
    /// アプリのコードと同じイメージにある型をさかのぼり、最初にほかのイメージにある親の型と、実装を比べる。
    fileprivate func overridesHitTesting(_ viewClass: AnyClass) -> Bool {
        let key = ObjectIdentifier(viewClass)
        if let known = overrides[key] {
            return known
        }
        let appImage = class_getImageName(HitAreaWindow.self).map { String(cString: $0) }
        var base: AnyClass = viewClass
        while class_getImageName(base).map({ String(cString: $0) }) == appImage, let superclass = class_getSuperclass(base) {
            base = superclass
        }
        let result = base !== viewClass && [#selector(UIView.hitTest(_:with:)), #selector(UIView.point(inside:with:))].contains { selector in
            class_getMethodImplementation(viewClass, selector) != class_getMethodImplementation(base, selector)
        }
        overrides[key] = result
        return result
    }

    /// 指を配る順（手前のウィンドウから）に並べた、このシーンのウィンドウ。同じ高さでは、あとに並ぶものが手前にある。
    private func targetWindows() -> [UIWindow] {
        guard let scene = windowScene else { return [] }
        let candidates = scene.windows.enumerated().filter { $0.element !== self && !$0.element.isHidden }
        return candidates.sorted { lhs, rhs in
            lhs.element.windowLevel == rhs.element.windowLevel
                ? lhs.offset > rhs.offset
                : lhs.element.windowLevel > rhs.element.windowLevel
        }.map(\.element)
    }

    private func hitView(at point: CGPoint, in targets: [UIWindow]) -> UIView? {
        for window in targets {
            let local = window.frame == frame ? point : window.convert(point, from: self)
            if let view = window.hitTest(local, with: nil) {
                return view
            }
        }
        return nil
    }

    /// 型の名前。SwiftUIの入れ物のように型の引数が長いものは、引数を省く。
    private static func typeName(of view: UIView) -> String {
        let name = String(describing: type(of: view))
        guard let bracket = name.firstIndex(of: "<") else { return name }
        return String(name[..<bracket])
    }

    /// ビューごとに決まる色。スクロールしても同じビューは同じ色のまま、隣り合うビューは違う色になりやすいよう、ビューの同一性から色相を散らす。
    private static func hue(for view: UIView) -> CGFloat {
        let hash = UInt64(UInt(bitPattern: ObjectIdentifier(view).hashValue)) &* 0x9E37_79B9_7F4A_7C15
        return CGFloat(hash >> 40) / CGFloat(1 << 24)
    }

    private static func color(for view: UIView, alpha: CGFloat) -> CGColor {
        UIColor(hue: hue(for: view), saturation: 0.85, brightness: 0.85, alpha: alpha).cgColor
    }

    /// 乗算済みのRGBA（バイト順で赤、緑、青、アルファ）。
    private static func premultiplied(for view: UIView, alpha: CGFloat) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(hue: hue(for: view), saturation: 0.85, brightness: 0.85, alpha: 1).getRed(&red, green: &green, blue: &blue, alpha: nil)
        let bytes = [red * alpha, green * alpha, blue * alpha, alpha].map { UInt32(($0 * 255).rounded()) }
        return (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]).bigEndian
    }
}
/// 範囲に書く名前。
private struct HitAreaLabel: Sendable {
    let view: Int32
    let name: String
    let color: CGColor
}

/// 描き直すかを決める、描いた結果の中身。
private struct HitAreaSignature: Equatable {
    let views: [ObjectIdentifier?]
    let frames: [CGRect]
    let size: CGSize
    let scale: CGFloat

    init(views: [UIView?], frames: [CGRect], size: CGSize, scale: CGFloat) {
        self.views = views.map { $0.map(ObjectIdentifier.init) }
        self.frames = frames
        self.size = size
        self.scale = scale
    }
}

/// 調べた点の結果から、画面の画素ごとに受けるビューを決める。
/// 4ptおきの点の結果をそのまま塗ると、境目が4ptの格子に丸められ、ビューの縁から最大4ptずれる。
/// まわりの点と受けるビューが違う点の中だけは、画素ごとに、まわりの点で受けたビューのうち、その画素を枠の中に含むものから、一番手前に描かれるものを選ぶ。
/// `hitTest`はビューの枠と親の枠の中で受けるので、そうしたビューの範囲の縁は枠の縁と一致する。
/// アプリのコードで`hitTest`か`point(inside:)`を上書きしたビューは、枠の一部だけで受けることがあるため、枠では決めず、点の結果のまま塗る。そうしたビューの範囲の縁は、格子に丸められたまま最大4ptずれる。
@MainActor
private struct HitAreaMap {
    /// 点の結果に出てきたビュー。`owners`はこの番号で持つ。
    let distinct: [UIView]
    /// 各ビューが受けうる範囲（ビューの枠と、すべての親の枠の重なり）。枠で決めないビューは`nil`。
    let frames: [CGRect]
    private let regions: [CGRect?]
    /// 手前に描かれるものほど大きい番号。
    private let paintOrder: [Int]
    private let cells: [Int32]
    private let columns: Int
    private let rows: Int
    private let step: CGFloat

    init(views: [UIView?], columns: Int, rows: Int, step: CGFloat, in window: HitAreaWindow, windows: [UIWindow]) {
        self.columns = columns
        self.rows = rows
        self.step = step
        var distinct: [UIView] = []
        var indices: [ObjectIdentifier: Int32] = [:]
        cells = views.map { view in
            guard let view else { return -1 }
            let key = ObjectIdentifier(view)
            if let index = indices[key] {
                return index
            }
            let index = Int32(distinct.count)
            indices[key] = index
            distinct.append(view)
            return index
        }
        self.distinct = distinct
        frames = distinct.map { $0.convert($0.bounds, to: window) }
        regions = zip(distinct, frames).map { view, frame in
            guard !window.overridesHitTesting(type(of: view)) else { return nil }
            var region = frame
            var ancestor = view.superview
            while let current = ancestor {
                region = region.intersection(current.convert(current.bounds, to: window))
                ancestor = current.superview
            }
            return region
        }
        // 奥のウィンドウから順に、親を子より先にたどって番号を振ると、手前に描かれるものほど大きい番号になる。
        var order: [ObjectIdentifier: Int] = [:]
        var counter = 0
        func visit(_ view: UIView) {
            counter += 1
            order[ObjectIdentifier(view)] = counter
            for subview in view.subviews {
                visit(subview)
            }
        }
        for target in windows.reversed() {
            visit(target)
        }
        paintOrder = distinct.map { order[ObjectIdentifier($0)] ?? 0 }
    }

    /// 画素ごとの計算に要る数値だけを取り出す。
    func raster(fill: (UIView) -> UInt32, line: (UIView) -> UInt32) -> HitAreaRaster {
        HitAreaRaster(cells: cells, columns: columns, rows: rows, step: step, regions: regions, paintOrder: paintOrder, fills: distinct.map(fill), lines: distinct.map(line))
    }

}

/// 画面の画素ごとに受けるビューを決めて描く、ビューに触らない数値だけの計算。決め方は`HitAreaMap`に書いた。
private struct HitAreaRaster: Sendable {
    let cells: [Int32]
    let columns: Int
    let rows: Int
    let step: CGFloat
    let regions: [CGRect?]
    let paintOrder: [Int]
    let fills: [UInt32]
    let lines: [UInt32]

    /// `size`の名前を置ける、`view`番のビューが受ける点だけで覆える一番上の左の位置。
    /// 左上から順に、同じビューが続く点の並びの左端だけを、200か所まで試す。広い範囲の上の端が細いとき、その並びの途中の点を試しても置けないため。
    func labelOrigin(for view: Int32, size: CGSize) -> CGPoint? {
        let spanX = Int((size.width / step).rounded(.up))
        let spanY = Int((size.height / step).rounded(.up))
        var tries = 0
        for row in 0..<rows {
            for column in 0..<columns where cells[row * columns + column] == view && (column == 0 || cells[row * columns + column - 1] != view) {
                tries += 1
                if tries > 200 {
                    return nil
                }
                guard column + spanX <= columns, row + spanY <= rows else { continue }
                let fits = (row..<(row + spanY)).allSatisfy { y in
                    (column..<(column + spanX)).allSatisfy { x in cells[y * columns + x] == view }
                }
                if fits {
                    return CGPoint(x: CGFloat(column) * step, y: CGFloat(row) * step)
                }
            }
        }
        return nil
    }

    /// 範囲ごとに、受けるビューの型の名前を書いた画像。名前は、範囲を囲む四角ではなく、そのビューが受ける点だけで覆える位置に置く。
    /// 折り返したリンクのように範囲が四角でないとき、囲む四角の左上がほかのビューの範囲になるため。置ける位置がない小さな範囲には書かない。
    func renderLabels(_ labels: [HitAreaLabel], size: CGSize, scale: CGFloat) -> CGImage? {
        let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for label in labels {
                let name = label.name as NSString
                let textSize = name.size(withAttributes: attributes)
                let background = CGSize(width: textSize.width + 2, height: textSize.height)
                guard let origin = labelOrigin(for: label.view, size: CGSize(width: background.width + 2, height: background.height + 2)) else { continue }
                let rect = CGRect(origin: CGPoint(x: origin.x + 1, y: origin.y + 1), size: background)
                context.cgContext.setFillColor(label.color)
                context.cgContext.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 2).cgPath)
                context.cgContext.fillPath()
                name.draw(at: CGPoint(x: rect.minX + 1, y: rect.minY), withAttributes: attributes)
            }
        }.cgImage
    }

    /// 画面の画素の、受けるビューの番号。どのビューも受けない画素は-1。
    func owners(width: Int, height: Int, scale: CGFloat) -> [Int32] {
        var owners = [Int32](repeating: -1, count: width * height)
        let columnPixels = Self.pixelRanges(count: columns, step: step * scale, limit: width)
        let rowPixels = Self.pixelRanges(count: rows, step: step * scale, limit: height)
        owners.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<rows {
                for column in 0..<columns {
                    let own = cells[row * columns + column]
                    let candidates = neighbors(column, row)
                    if candidates.count == 1, candidates[0] == own {
                        for y in rowPixels[row] {
                            buffer[(y * width + columnPixels[column].lowerBound)..<(y * width + columnPixels[column].upperBound)].update(repeating: own)
                        }
                        continue
                    }
                    for y in rowPixels[row] {
                        for x in columnPixels[column] {
                            let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                            buffer[y * width + x] = owner(at: point, own: own, candidates: candidates)
                        }
                    }
                }
            }
        }
        return owners
    }

    /// 範囲を薄く塗り、ほかのビューとの境目に、範囲の内側へ1画素の線を引いた画像。隣り合う範囲の線が並ぶので、境目の両側の色が分かる。
    func render(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let owners = owners(width: width, height: height, scale: scale)
        var pixels = [UInt32](repeating: 0, count: width * height)
        owners.withUnsafeBufferPointer { owners in
            pixels.withUnsafeMutableBufferPointer { pixels in
                for y in 0..<height {
                    for x in 0..<width {
                        let index = y * width + x
                        let owner = owners[index]
                        guard owner >= 0 else { continue }
                        let isEdge = (x > 0 && owners[index - 1] != owner)
                            || (x + 1 < width && owners[index + 1] != owner)
                            || (y > 0 && owners[index - width] != owner)
                            || (y + 1 < height && owners[index + width] != owner)
                        pixels[index] = isEdge ? lines[Int(owner)] : fills[Int(owner)]
                    }
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// その点とまわりの8点で受けたビュー。手前に描かれるものから並べる。
    private func neighbors(_ column: Int, _ row: Int) -> [Int32] {
        var found: [Int32] = []
        for y in max(row - 1, 0)...min(row + 1, rows - 1) {
            for x in max(column - 1, 0)...min(column + 1, columns - 1) {
                let index = cells[y * columns + x]
                if !found.contains(index) {
                    found.append(index)
                }
            }
        }
        return found.sorted { paintOrder(of: $0) > paintOrder(of: $1) }
    }

    private func paintOrder(of index: Int32) -> Int {
        index < 0 ? -1 : paintOrder[Int(index)]
    }

    /// 画素を含むビューのうち一番手前のもの。枠で決めないビューは、その画素の点で受けたときだけ含むとする。どれも含まなければ、その画素の点の結果にする。
    private func owner(at point: CGPoint, own: Int32, candidates: [Int32]) -> Int32 {
        for candidate in candidates where candidate >= 0 {
            if let region = regions[Int(candidate)] {
                if region.contains(point) {
                    return candidate
                }
            } else if candidate == own {
                return candidate
            }
        }
        return own
    }

    /// 点ごとの、画面の画素の範囲。
    private static func pixelRanges(count: Int, step: CGFloat, limit: Int) -> [Range<Int>] {
        (0..<count).map { index in
            let start = min(Int((CGFloat(index) * step).rounded()), limit)
            let end = min(Int((CGFloat(index + 1) * step).rounded()), limit)
            return start..<max(start, end)
        }
    }
}

/// 点ごとに受けるビューを、区画に分けて調べる。区画の角と中心が同じビューを受け、細かく調べる点（`detail`）も含まない区画は、まとめてそのビューで埋める。
/// 画面のすべての点で`hitTest`を呼ぶと、タイムラインの画面で1回に0.6秒ほどかかったため、境目の近くだけを細かく調べる。
/// フレームに分けて調べられるよう、調べ残した区画を積んでおき、`advance`で続きから調べる。
private struct HitGrid {
    /// 最初に分ける区画の一辺の点の数。2のべき乗にする。
    private static let blockSize = 4

    let columns: Int
    let rows: Int
    private(set) var views: [UIView?]
    private let detail: [Bool]
    private let hit: (Int, Int) -> UIView?
    private var sampled: [Bool]
    private var blocks: [(column: Int, row: Int, size: Int)] = []

    init(columns: Int, rows: Int, detail: [Bool], hit: @escaping (Int, Int) -> UIView?) {
        self.columns = columns
        self.rows = rows
        self.detail = detail
        self.hit = hit
        views = [UIView?](repeating: nil, count: columns * rows)
        sampled = [Bool](repeating: false, count: columns * rows)
        // 積んだものを後ろから取り出すので、左上から調べるよう逆に積む。
        for row in stride(from: 0, to: rows, by: Self.blockSize).reversed() {
            for column in stride(from: 0, to: columns, by: Self.blockSize).reversed() {
                blocks.append((column, row, Self.blockSize))
            }
        }
    }

    /// `shouldPause`がtrueを返すまで調べる。調べ終えたらtrueを返す。
    mutating func advance(shouldPause: () -> Bool) -> Bool {
        while let block = blocks.popLast() {
            resolve(column: block.column, row: block.row, size: block.size)
            if shouldPause() {
                return blocks.isEmpty
            }
        }
        return true
    }

    private mutating func resolve(column: Int, row: Int, size: Int) {
        let maxColumn = min(column + size, columns) - 1
        let maxRow = min(row + size, rows) - 1
        if size == 1 || maxColumn == column && maxRow == row {
            _ = value(column, row)
            return
        }
        let first = value(column, row)
        let probes = [(maxColumn, row), (column, maxRow), (maxColumn, maxRow), ((column + maxColumn) / 2, (row + maxRow) / 2)]
        let isUniform = probes.allSatisfy { value($0.0, $0.1) === first } && !needsDetail(column...maxColumn, row...maxRow)
        if isUniform {
            for y in row...maxRow {
                for x in column...maxColumn {
                    views[y * columns + x] = first
                }
            }
            return
        }
        let half = size / 2
        for (dx, dy) in [(half, half), (0, half), (half, 0), (0, 0)] where column + dx < columns && row + dy < rows {
            blocks.append((column + dx, row + dy, half))
        }
    }

    private func needsDetail(_ columnRange: ClosedRange<Int>, _ rowRange: ClosedRange<Int>) -> Bool {
        rowRange.contains { y in columnRange.contains { x in detail[y * columns + x] } }
    }

    private mutating func value(_ column: Int, _ row: Int) -> UIView? {
        let index = row * columns + column
        if !sampled[index] {
            views[index] = hit(column, row)
            sampled[index] = true
        }
        return views[index]
    }
}
