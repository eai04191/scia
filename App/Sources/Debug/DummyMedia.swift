#if DEBUG
import SciaCore
import UIKit

/// ビューアを確かめるための、通信せずに表示できるダミーの添付ファイル。
/// 画像は端末で描いてdata URLにする。画像の読み込みはURLSessionで行い、data URLもそのまま読めるため。
enum DummyMedia {
    private struct Spec {
        let size: CGSize
        let color: UIColor
        let label: String
        let description: String?
    }

    /// 形の違う4枚。一覧の並べ方と、ビューアでの開閉や拡大を、縦長・横長・正方形・細長で比べられるようにする。
    private static let specs = [
        Spec(size: CGSize(width: 900, height: 1_600), color: .systemBlue, label: "1 縦長", description: "縦長の画像（9:16）"),
        Spec(size: CGSize(width: 1_600, height: 900), color: .systemGreen, label: "2 横長", description: nil),
        Spec(size: CGSize(width: 1_200, height: 1_200), color: .systemOrange, label: "3 正方形", description: "正方形の画像"),
        Spec(size: CGSize(width: 600, height: 2_000), color: .systemPurple, label: "4 細長", description: nil),
    ]

    /// - Parameter idPrefix: 添付ファイルのIDの頭に付ける。投稿ごとに変え、ビューアが別の投稿のサムネイルへ戻らないようにする。
    static func attachments(idPrefix: String) -> [MediaAttachment] {
        specs.enumerated().compactMap { index, spec in
            guard let url = dataURL(for: spec) else { return nil }
            let size = MediaAttachment.Size(width: Int(spec.size.width), height: Int(spec.size.height))
            return MediaAttachment(
                id: "\(idPrefix)-\(index)",
                type: .image,
                url: url,
                previewUrl: url,
                description: spec.description,
                meta: MediaAttachment.Meta(original: size)
            )
        }
    }

    /// 単色に100pxの格子と番号を描く。格子で、拡大や切り抜きのずれを見分けられるようにする。
    private static func dataURL(for spec: Spec) -> URL? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: spec.size, format: format).image { context in
            spec.color.setFill()
            context.fill(CGRect(origin: .zero, size: spec.size))
            let grid = UIBezierPath()
            for x in stride(from: 0, through: spec.size.width, by: 100) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: spec.size.height))
            }
            for y in stride(from: 0, through: spec.size.height, by: 100) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: spec.size.width, y: y))
            }
            grid.lineWidth = 2
            UIColor.white.setStroke()
            grid.stroke()
            let text = NSAttributedString(string: spec.label, attributes: [
                .font: UIFont.boldSystemFont(ofSize: min(spec.size.width, spec.size.height) / 4),
                .foregroundColor: UIColor.white,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (spec.size.width - textSize.width) / 2, y: (spec.size.height - textSize.height) / 2))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        return URL(string: "data:image/jpeg;base64,\(data.base64EncodedString())")
    }
}
#endif
