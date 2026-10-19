#if DEBUG
import Foundation
import SciaCore
import UIKit

/// カタログの部品に渡す、通信せずに出せるデータと、読み込みの途中や失敗で止まる画像の読み込み口。
enum CatalogFixtures {
    /// 単色に格子を描いた画像のdata URL。画像の読み込みはURLSessionで行い、data URLもそのまま読めるため、本物の読み込み口のまま通信せずに出せる。
    static func imageURL(width: Int, height: Int, color: UIColor, label: String = "") -> URL? {
        let image = DummyMedia.image(size: CGSize(width: width, height: height), color: color, label: label)
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        return URL(string: "data:image/jpeg;base64,\(data.base64EncodedString())")
    }

    /// HLGのHDRの画像。読み込むと、一覧のサムネイルがHDRと判定する。
    static func hdrImageURL(width: Int, height: Int, color: UIColor, label: String = "") -> URL? {
        let image = DummyMedia.image(size: CGSize(width: width, height: height), color: color, label: label)
        guard let source = CIImage(image: image),
              let space = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
              let data = CIContext().pngRepresentation(of: source, format: .RGBA16, colorSpace: space)
        else { return nil }
        return URL(string: "data:image/png;base64,\(data.base64EncodedString())")
    }

    /// 画像が届くまで出すぼかしの下地。blurhashの説明でよく使われる例の値。
    static let blurhash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

    /// 読み込みが終わらない。届く前の見た目を固定する。
    @MainActor
    static let pendingMediaImages = MediaImageStore(files: catalogFiles(name: "Pending")) { _, _ in
        try await Task.sleep(for: .seconds(86_400))
        throw CancellationError()
    }

    /// 読み込みがすぐ失敗する。
    @MainActor
    static let failingMediaImages = MediaImageStore(files: catalogFiles(name: "Failing")) { _, _ in
        throw URLError(.notConnectedToInternet)
    }

    /// アプリのキャッシュと取り合わないよう、カタログの読み込み口ごとに置き場所を分ける。
    /// `MediaFileCache`は作るときに共有用の置き場所を消すため、アプリと同じ場所を渡すと共有中のファイルまで消える。
    private static func catalogFiles(name: String) -> MediaFileCache {
        let root = URL.temporaryDirectory.appending(path: "Catalog\(name)", directoryHint: .isDirectory)
        return MediaFileCache(directory: root.appending(path: "MediaFiles"), sharingDirectory: root.appending(path: "MediaSharing"))
    }

    static func attachment(
        _ id: String,
        type: MediaAttachment.Kind = .image,
        width: Int,
        height: Int,
        color: UIColor = .systemBlue,
        label: String = "",
        description: String? = nil,
        blurhash: String? = nil,
        hasPreview: Bool = true,
        hdr: Bool = false
    ) -> MediaAttachment {
        let url = !hasPreview ? nil : hdr
            ? hdrImageURL(width: width, height: height, color: color, label: label)
            : imageURL(width: width, height: height, color: color, label: label)
        return MediaAttachment(
            id: id,
            type: type,
            url: url,
            previewUrl: url,
            description: description,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: width, height: height)),
            blurhash: blurhash
        )
    }

    static func account(
        displayName: String = "カタログ",
        acct: String = "catalog@example.com",
        avatar: URL? = imageURL(width: 200, height: 200, color: .systemTeal),
        header: URL? = nil,
        note: String = "",
        fields: [Account.Field] = [],
        locked: Bool = false,
        bot: Bool = false
    ) -> Account {
        Account(
            id: acct,
            username: acct.components(separatedBy: "@").first ?? acct,
            acct: acct,
            displayName: displayName,
            avatar: avatar,
            header: header,
            note: note,
            url: URL(string: "https://example.com/@catalog"),
            fields: fields,
            locked: locked,
            bot: bot,
            followersCount: 1_234,
            followingCount: 56,
            statusesCount: 7_890
        )
    }
}
#endif
