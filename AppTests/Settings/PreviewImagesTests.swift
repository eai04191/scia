import Testing
import UIKit
@testable import Scia

@MainActor
struct PreviewImagesTests {
    /// 見本の画像は通信の層を通さずに読む。通信の層はhttpとhttps以外を送らず、Releaseには`file:`を読む障害の差し込みもないため、
    /// ファイルのURLを渡すと、Releaseでだけ灰色の四角のまま出なかった。
    @Test(arguments: ["avatar", "card-light", "card-dark"])
    func loadsWithoutNetwork(name: String) async throws {
        let url = try #require(Self.url(named: name))
        #expect(!url.isFileURL)
        #expect(url.scheme != "http" && url.scheme != "https")
        let data = try await AppDependencies.imageData(from: url)
        #expect(UIImage(data: data) != nil)
    }

    private static func url(named name: String) -> URL? {
        switch name {
        case "avatar": PreviewImages.avatarURL()
        case "card-light": PreviewImages.cardURL(for: .light)
        default: PreviewImages.cardURL(for: .dark)
        }
    }
}
