import MemoryCache
import SciaCore
import UIKit

/// Unicodeの絵文字を、メインスレッドの外で画像にして持つ。
/// 文字として描くと、初めて描く絵文字はメインスレッドで絵を作る。絵文字ピッカーを速くスクロールすると、1フレームに何十個も初めて描くことになり、フレームが落ちた。
/// メモリにない絵文字は、作り終えるまで、端末に置いた画像（`EmojiGlyphArchive`）で描く。
@MainActor
final class EmojiGlyphImageStore {
    struct Request: Hashable, Sendable {
        var text: String
        var pointSize: CGFloat
        var style: EmojiStyle
        /// 描く枠（ポイント）。絵文字は中央に置く。
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        /// twemojiでは「©」のように文字のまま描く絵文字があり、文字の色は外観で変わる。
        var userInterfaceStyle: UIUserInterfaceStyle
    }

    typealias Render = @Sendable (Request) async -> UIImage

    private struct Listener {
        weak var owner: AnyObject?
        var onLoad: @MainActor (Request, UIImage) -> Void
    }

    private let render: Render
    private var images = MemoryCache<Request, UIImage>(totalCostLimit: 16 * 1024 * 1024)
    private var rendering: Set<Request> = []
    private var listeners: [Listener] = []
    /// 求められた数と、持っていて返せた数。返せなかった分だけ、絵文字のパレットの枠が空く。
    private var lookups = 0
    private var hits = 0
    /// 作った数と、一度作ったのに上限を超えて捨て、また作った数。
    private var renders = 0
    private var rerenders = 0
    private var everRendered: Set<Request> = []
    /// 作り始めてから届けるまでのミリ秒（作るのを待つ間を含む）。新しいほうから1024個まで。
    private var renderDelays: [Double] = []

    init(render: @escaping Render = EmojiGlyphImageStore.draw) {
        self.render = render
    }

    /// 持っていれば返す。持っていなければ作り始め、できたら`addListener`で登録したところへ渡す。
    func image(for request: Request) -> UIImage? {
        lookups += 1
        if let image = images.value(forKey: request) {
            hits += 1
            return image
        }
        guard rendering.insert(request).inserted else { return nil }
        let startedAt = AppDependencies.mediaTime()
        Task(.withoutRequests) { await self.load(request, startedAt: startedAt) }
        return nil
    }

    private func load(_ request: Request, startedAt: CFTimeInterval) async {
        let image = await render(request)
        rendering.remove(request)
        renders += 1
        if !everRendered.insert(request).inserted {
            rerenders += 1
        }
        renderDelays.append((AppDependencies.mediaTime() - startedAt) * 1_000)
        if renderDelays.count > 1_024 {
            renderDelays.removeFirst(renderDelays.count - 1_024)
        }
        images.setValue(image, forKey: request, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        listeners.removeAll { $0.owner == nil }
        for listener in listeners {
            listener.onLoad(request, image)
        }
    }

    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Request, UIImage) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    /// 状態ダンプ。絵文字は出さず、数だけを書く。
    func stateDump() -> String {
        let sorted = renderDelays.sorted()
        func at(_ ratio: Double) -> String { sorted.isEmpty ? "-" : String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * ratio))]) }
        return [
            "glyphs: \(images.count) cost: \(images.totalCost / 1024)KB limit: \(images.totalCostLimit / 1024)KB",
            "lookups: \(lookups) hits: \(hits) renders: \(renders) rerendersAfterEviction: \(rerenders)",
            "renderDelayMs: p50 \(at(0.5)) p90 \(at(0.9)) max \(sorted.last.map { String(format: "%.1f", $0) } ?? "-")",
        ].joined(separator: "\n")
    }

    func releaseUnusedMemory() {
        images.releaseUnused()
    }

    /// 枠の中央に、文字として描く。枠より広い並び（端末の絵文字の書体が1つの絵にできない並び）は、半分の大きさまで縮める。
    @concurrent
    static func draw(_ request: Request) async -> UIImage {
        drawNow(request)
    }

    /// その場で描く。メニューのアイコンのように、数個をすぐ出すときに使う。
    nonisolated static func drawNow(_ request: Request) -> UIImage {
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: request.userInterfaceStyle))
        func string(scaledBy factor: CGFloat) -> NSAttributedString {
            // 枠の大きさで決めた大きさを受け取るので、端末の文字の大きさには合わせない。
            // scialint:disable:next fixed_font_size
            let font = EmojiFont.font(.systemFont(ofSize: request.pointSize * factor), style: request.style)
            return NSAttributedString(string: request.text, attributes: [.font: font, .foregroundColor: color])
        }
        var text = string(scaledBy: 1)
        var size = text.size()
        if size.width > request.width {
            text = string(scaledBy: max(request.width / size.width, 0.5))
            size = text.size()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = request.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: request.width, height: request.height), format: format).image { _ in
            text.draw(at: CGPoint(x: (request.width - size.width) / 2, y: (request.height - size.height) / 2))
        }
    }
}
