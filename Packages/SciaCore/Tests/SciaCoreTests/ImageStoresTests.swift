import CoreGraphics
import Foundation
import ImageIO
import SciaTesting
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

/// 画像のストアの組み立てと、サムネイルにどの画像を読むかの条件。
@MainActor
@Suite(.scratch, .requestPurpose(.display))
struct ImageStoresTests {
    private let root = TestScratch.url("ImageStoresTests")

    private nonisolated static func png() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 通信を1度も通さないストア。通れば失敗する。
    private func makeStores(settings: AppSettings? = nil, localData: @escaping @Sendable (URL) async -> Data?) -> ImageStores<CGImage> {
        let http = HTTPClient(transport: StubTransport([]), retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock(), now: { Date(timeIntervalSince1970: 0) })
        return ImageStores(
            http: http,
            tuning: TuningStore(defaults: nil),
            network: NetworkConditionsMonitor(monitor: nil),
            settings: settings ?? AppSettings(defaults: TestScratch.defaults("ImageStoresTests.stores")),
            maker: PlatformImageMaker<CGImage>(still: { $0 }, animated: { _, _ in nil }),
            clock: TestClock(),
            localData: localData,
            mediaFiles: MediaFileCache(directory: root.appending(path: "files"), sharingDirectory: root.appending(path: "sharing")) { Date(timeIntervalSince1970: 0) },
            mediaPrefetchFiles: MediaFileCache(directory: root.appending(path: "prefetch"), sharingDirectory: root.appending(path: "prefetch-sharing")) { Date(timeIntervalSince1970: 0) },
            customEmojis: CustomEmojiCaches(directory: root.appending(path: "emojis"), clock: TestClock()),
            emojiImageDirectory: root.appending(path: "emoji-images")
        )
    }

    /// 通信せずに返せる画像は、アイコンでも添付ファイルでも通信せずに使う。
    @Test func localDataIsUsedWithoutNetwork() async throws {
        let png = try Self.png()
        let url = try #require(URL(string: "https://example.social/preview.png"))
        let stores = makeStores { $0 == url ? png : nil }

        _ = try await stores.avatars.image(for: AvatarImageKey(url: url, maxPixelSize: 8, animates: false))
        _ = try await stores.media.image(for: url, maxPixelSize: 8, purpose: .display)
    }

    @Test func savedUserImageLoadsAsAvatarAndViewerWithoutNetwork() async throws {
        let store = SettingsStore(defaults: TestScratch.defaults("savedAvatar"), userDisplayImageDirectory: root.appending(path: "saved"))
        let settings = AppSettings(store: store, target: .scope(.app)).forAccount("@me@example.com")
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        settings.setUserDisplayDomain("example.com")
        try settings.userDisplays.save(.init(), for: account, in: settings, imageData: Self.png())
        let url = try #require(settings.userDisplays.display(of: account, in: settings).avatar)
        let stores = makeStores(settings: settings) { _ in nil }
        let avatar = try await stores.avatars.image(for: AvatarImageKey(url: url, maxPixelSize: 8, animates: false))
        let viewer = try await stores.media.image(for: url, maxPixelSize: 8, purpose: .display)
        #expect(avatar.width == 8)
        #expect(viewer.width == 8)
    }

    /// 元の画像を読むかと先読みするかは回線と設定で、プレビュー画像を引き伸ばしてよい倍率はチューニングで決める。
    @Test func thumbnailPolicyCombinesNetworkSettingsAndTuning() throws {
        let settings = AppSettings(defaults: TestScratch.defaults("ImageStoresTests"))
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(1.5, for: TuningCatalog.mediaThumbnailUpscaleTolerance)
        let network = NetworkConditionsMonitor(monitor: nil)

        #expect(network.thumbnailPolicy(settings: settings, tuning: tuning) == MediaThumbnailPolicy(enhancement: .enhancement(onExpensiveNetwork: true), upscaleTolerance: 1.5, prefetch: .prefetch))

        // モバイル通信では先読みしない。設定で元の画像を読まないなら、元の画像も読まない。
        network.receive(isSatisfied: true, conditions: NetworkConditions(isConstrained: false, isExpensive: true))
        settings.usesOriginalThumbnailsOnExpensiveNetwork = false
        #expect(network.thumbnailPolicy(settings: settings, tuning: tuning) == MediaThumbnailPolicy(enhancement: nil, upscaleTolerance: 1.5, prefetch: nil))
    }
}
