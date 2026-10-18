public import Foundation
public import Observation

/// 対応形式として返しているのに、サーバーが処理できなかった画像の形式を、サーバーとその版ごとに覚える。
///
/// Mastodon 4.7.2と4.7.3は、`supported_mime_types`にHEIC、HEIF、AVIFを載せたまま、画像の読み込みを止めていて、送ると`POST /api/v2/media`が500を返す。
/// 一度失敗したら、同じ版の間はその形式を送らず、起動し直しても覚えておく。版が変われば、サーバーが直ったかもしれないので、もう一度試す。
@MainActor
@Observable
public final class UnprocessableMediaFormats {
    public struct Entry: Sendable, Equatable, Codable {
        public let mimeType: String
        /// 処理できなかったときのサーバーの版。版を読めていなかったときは空。
        public let serverVersion: String
        public let date: Date
    }

    /// 処理できないと覚えた形式。覚えた順。
    public private(set) var entries: [Entry]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    /// 送り直したときにJPEGにする形式。これ以外の形式では、処理の失敗を形式のせいとみなさない。
    public static let replaceableMIMETypes: Set<String> = ["image/heic", "image/heif", "image/avif"]

    public init(defaults: UserDefaults, instance: URL) {
        self.defaults = defaults
        key = "media.unprocessableFormats.\(instance.host() ?? instance.absoluteString)"
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// 今の版のサーバーに送らない形式。
    public func mimeTypes(serverVersion: String?) -> Set<String> {
        Set(entries.filter { $0.serverVersion == (serverVersion ?? "") }.map(\.mimeType))
    }

    /// 形式を、今の版のサーバーでは使わないと覚える。前の版で覚えていたものは、版を改めて覚え直す。
    public func record(_ mimeType: String, serverVersion: String?, date: Date = Date()) {
        let version = serverVersion ?? ""
        guard !entries.contains(where: { $0.mimeType == mimeType && $0.serverVersion == version }) else { return }
        entries.removeAll { $0.mimeType == mimeType }
        entries.append(Entry(mimeType: mimeType, serverVersion: version, date: date))
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }

    /// 失敗を、形式のせいとみなしてJPEGで送り直すか。
    ///
    /// サーバーの処理の失敗はどれも同じ500と文言で返り、形式のせいかを応答から見分けられない。
    /// そのため、処理できないことのある形式で、アップロードの処理に失敗したときだけを形式のせいとみなす。
    public static func shouldReplaceWithJPEG(mimeType: String, error: any Error) -> Bool {
        guard replaceableMIMETypes.contains(mimeType), case .processingFailed(let apiError) = error as? MediaUploadError else { return false }
        return apiError.statusCode == 500
    }
}
