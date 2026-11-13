import MemoryCache
import SciaCore
import UIKit

/// Unicodeの絵文字を、メインスレッドの外で画像にして持つ。
/// 文字として描くと、初めて描く絵文字はメインスレッドで絵を作る。絵文字のパレットを速くスクロールすると、1フレームに何十個も初めて描くことになり、フレームが落ちた。
/// 端末には残さない。作るのは1つ1ms未満で、絵はiOSの版、絵文字の絵の設定、大きさ、外観で変わる。
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

    init(render: @escaping Render = EmojiGlyphImageStore.draw) {
        self.render = render
    }

    /// 持っていれば返す。持っていなければ作り始め、できたら`addListener`で登録したところへ渡す。
    func image(for request: Request) -> UIImage? {
        if let image = images.value(forKey: request) { return image }
        guard rendering.insert(request).inserted else { return nil }
        Task(.withoutRequests) { await self.load(request) }
        return nil
    }

    private func load(_ request: Request) async {
        let image = await render(request)
        rendering.remove(request)
        images.setValue(image, forKey: request, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        listeners.removeAll { $0.owner == nil }
        for listener in listeners {
            listener.onLoad(request, image)
        }
    }

    func addListener(owner: AnyObject, onLoad: @escaping @MainActor (Request, UIImage) -> Void) {
        listeners.append(Listener(owner: owner, onLoad: onLoad))
    }

    func releaseUnusedMemory() {
        images.releaseUnused()
    }

    /// 枠の中央に、文字として描く。枠より広い並び（端末の絵文字の書体が1つの絵にできない並び）は、半分の大きさまで縮める。
    @concurrent
    static func draw(_ request: Request) async -> UIImage {
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
