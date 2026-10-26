#if DEBUG
import Foundation
import UIKit

/// シナリオの投稿や通知を、Mastodon APIと同じ形のJSONで作る。
/// SciaCoreのモデルをエンコードせずに組み立てるのは、モデルのデコードが欠けた項目を補うため、エンコードし直した形がAPIと同じになる保証がないから。
enum ScenarioFixtures {
    /// シナリオに出るアカウント。
    struct Person: Sendable {
        let id: String
        let username: String
        let displayName: String
        /// アイコンのdata URL。
        let avatar: String
    }

    /// 添付する画像。
    struct Picture: Sendable {
        let url: String
        let width: Int
        let height: Int
        let description: String?
    }

    static let domain = "mastodon.example"

    /// Mastodonの投稿IDと同じく、ミリ秒の時刻を16ビット左へずらし、下位に連番を入れる。時刻順に並び、桁がそろう。
    static func id(at date: Date, sequence: Int) -> String {
        String(UInt64(date.timeIntervalSince1970 * 1000) << 16 | UInt64(sequence & 0xFFFF))
    }

    static func account(_ person: Person) -> [String: Any] {
        [
            "id": person.id,
            "username": person.username,
            "acct": person.username,
            "display_name": person.displayName,
            "locked": false,
            "bot": false,
            "created_at": "2022-04-01T00:00:00.000Z",
            "note": "",
            "url": "https://\(domain)/@\(person.username)",
            "avatar": person.avatar,
            "avatar_static": person.avatar,
            "header": "",
            "header_static": "",
            "followers_count": 120,
            "following_count": 80,
            "statuses_count": 3_400,
            "emojis": [Any](),
            "fields": [Any](),
        ]
    }

    static func status(id: String, createdAt: Date, by person: Person, text: String, pictures: [Picture] = [], favourites: Int = 0) -> [String: Any] {
        [
            "id": id,
            "created_at": timestamp(createdAt),
            "in_reply_to_id": NSNull(),
            "in_reply_to_account_id": NSNull(),
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "public",
            "language": "ja",
            "uri": "https://\(domain)/users/\(person.username)/statuses/\(id)",
            "url": "https://\(domain)/@\(person.username)/\(id)",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": favourites,
            "favourited": false,
            "reblogged": false,
            "bookmarked": false,
            "content": html(text),
            "reblog": NSNull(),
            "account": account(person),
            "media_attachments": pictures.enumerated().map { index, picture in attachment(picture, id: "\(id)\(index)") },
            "mentions": [Any](),
            "tags": [Any](),
            "emojis": [Any](),
            "card": NSNull(),
            "poll": NSNull(),
        ]
    }

    /// - Parameter status: フォローのように投稿のない通知ではnil。
    static func notification(id: String, type: String, createdAt: Date, by person: Person, status: [String: Any]?) -> [String: Any] {
        [
            "id": id,
            "type": type,
            "created_at": timestamp(createdAt),
            "account": account(person),
            "status": status ?? NSNull(),
        ]
    }

    /// ストリーミングで届くメッセージ。`payload`はJSONを文字列にしたもの。
    static func streamingMessage(event: String, payload: [String: Any]) -> String {
        let payloadText = String(decoding: json(payload), as: UTF8.self)
        return String(decoding: json(["stream": ["user"], "event": event, "payload": payloadText]), as: UTF8.self)
    }

    /// シナリオはこのファイルの関数で組み立てるので、JSONにできないのはシナリオの誤り。
    static func json(_ object: Any) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            preconditionFailure("シナリオをJSONにできない: \(error)")
        }
    }

    private static func attachment(_ picture: Picture, id: String) -> [String: Any] {
        let size: [String: Any] = ["width": picture.width, "height": picture.height, "aspect": Double(picture.width) / Double(picture.height)]
        return [
            "id": id,
            "type": "image",
            "url": picture.url,
            "preview_url": picture.url,
            "remote_url": NSNull(),
            "description": picture.description ?? NSNull(),
            "blurhash": NSNull(),
            "meta": ["original": size, "small": size],
        ]
    }

    /// 段落ごとに`<p>`で包み、段落の中の改行を`<br>`にする。
    private static func html(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            let escaped = paragraph
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(escaped)</p>"
        }.joined()
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}

/// シナリオのアイコンと写真を、通信せずに端末で描く。
enum ScenarioArtwork {
    /// 色の地に1文字を白く描いたアイコン。
    static func avatar(_ character: String, color: UIColor) -> String {
        let size = CGSize(width: 240, height: 240)
        let image = renderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = NSAttributedString(string: character, attributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.white,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        }
        return dataURL(image)
    }

    /// 空のグラデーションに、太陽と2つの丘を重ねた風景。
    struct Landscape {
        let sky: (top: UIColor, bottom: UIColor)
        let sun: UIColor
        let hills: (far: UIColor, near: UIColor)
    }

    static func landscape(_ landscape: Landscape, size: CGSize, description: String? = nil) -> ScenarioFixtures.Picture {
        let image = landscapeImage(landscape, size: size)
        return ScenarioFixtures.Picture(url: dataURL(image), width: Int(size.width), height: Int(size.height), description: description)
    }

    /// 風景の画像。投稿欄の添付のように、data URLではなく画像のまま渡す場面に使う。
    static func landscapeImage(_ landscape: Landscape, size: CGSize) -> UIImage {
        renderer(size: size).image { context in
            let cgContext = context.cgContext
            let colors = [landscape.sky.top.cgColor, landscape.sky.bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let sunSide = min(size.width, size.height) * 0.22
            landscape.sun.setFill()
            cgContext.fillEllipse(in: CGRect(x: size.width * 0.62, y: size.height * 0.28, width: sunSide, height: sunSide))
            hill(in: size, baseline: 0.68, amplitude: 0.08, phase: 0.3, color: landscape.hills.far)
            hill(in: size, baseline: 0.80, amplitude: 0.06, phase: 1.7, color: landscape.hills.near)
        }
    }

    /// 横へゆるく波打つ丘。`baseline`と`amplitude`は高さに対する割合。
    private static func hill(in size: CGSize, baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: size.height))
        for step in 0...40 {
            let x = size.width * CGFloat(step) / 40
            let y = size.height * (baseline + amplitude * sin(CGFloat(step) / 40 * .pi * 2 + phase))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.close()
        color.setFill()
        path.fill()
    }

    private static func renderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func dataURL(_ image: UIImage) -> String {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            preconditionFailure("シナリオの画像をJPEGにできない")
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
#endif
