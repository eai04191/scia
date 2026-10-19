import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

struct MediaThumbnailSelectionTests {
    private let original = URL(string: "https://example.com/original.png")
    private let preview = URL(string: "https://example.com/small.png")
    private let allowsOriginal = MediaThumbnailPolicy(allowsOriginal: true, upscaleTolerance: 1)

    private func attachment(
        _ type: MediaAttachment.Kind = .image,
        original originalSize: (Int, Int)? = (3_840, 2_160),
        small smallSize: (Int, Int)? = (640, 360),
        hasOriginalURL: Bool = true
    ) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: hasOriginalURL ? original : nil,
            previewUrl: preview,
            meta: MediaAttachment.Meta(
                original: originalSize.map { MediaAttachment.Size(width: $0.0, height: $0.1) },
                small: smallSize.map { MediaAttachment.Size(width: $0.0, height: $0.1) }
            )
        )
    }

    private func request(
        _ attachment: MediaAttachment,
        tile: CGSize = CGSize(width: 340, height: 191.25),
        scale: Double = 3,
        policy: MediaThumbnailPolicy? = nil
    ) -> MediaThumbnailRequest? {
        MediaThumbnailSelection.request(for: attachment, tileSize: tile, displayScale: scale, policy: policy ?? allowsOriginal)
    }

    /// iPhone 16 Proで幅いっぱいに出すと約1,000ピクセル要り、640ピクセルのプレビューでは足りない。
    @Test func readsOriginalWhenPreviewIsTooSmallForTheTile() {
        #expect(request(attachment())?.url == original)
    }

    @Test func readsPreviewWhenItCoversTheTile() {
        #expect(request(attachment(), tile: CGSize(width: 160, height: 90), scale: 3)?.url == preview)
    }

    /// 引き伸ばしてよい倍率までなら、プレビューで足りるとみなす。
    @Test func upscaleToleranceAcceptsASlightlySmallerPreview() {
        let tolerant = MediaThumbnailPolicy(allowsOriginal: true, upscaleTolerance: 1.6)
        #expect(request(attachment(), policy: tolerant)?.url == preview)
        let strict = MediaThumbnailPolicy(allowsOriginal: true, upscaleTolerance: 1.5)
        #expect(request(attachment(), policy: strict)?.url == original)
    }

    /// 低データモードなどで元の画像を読まないときは、足りなくてもプレビューを読む。
    @Test func readsPreviewWhenOriginalIsNotAllowed() {
        let policy = MediaThumbnailPolicy(allowsOriginal: false, upscaleTolerance: 1)
        #expect(request(attachment(), policy: policy)?.url == preview)
    }

    /// 元の画像を読まない条件では、プレビュー画像がなくても元の画像へ切り替えない。
    @Test func readsNothingWithoutPreviewWhenOriginalIsNotAllowed() {
        let noPreview = MediaAttachment(id: "1", type: .image, url: original, previewUrl: nil)
        let policy = MediaThumbnailPolicy(allowsOriginal: false, upscaleTolerance: 1)
        #expect(request(noPreview, policy: policy) == nil)
        #expect(request(noPreview)?.url == original)
    }

    /// プレビュー画像の大きさが分からないサーバーでは、足りるか分からないため元の画像を読む。
    @Test func readsOriginalWhenPreviewSizeIsUnknown() {
        #expect(request(attachment(small: nil), tile: CGSize(width: 50, height: 50))?.url == original)
    }

    /// 元の画像がプレビューと同じ大きさなら、読み直しても細かくならない。
    @Test func readsPreviewWhenOriginalIsNoLargerThanPreview() {
        #expect(request(attachment(original: (400, 300), small: (400, 300)))?.url == preview)
    }

    @Test func readsPreviewWhenThereIsNoOriginalURL() {
        #expect(request(attachment(hasOriginalURL: false))?.url == preview)
    }

    private func video(
        _ type: MediaAttachment.Kind = .video,
        preview: String = "https://files.example.social/media_attachments/files/111/222/333/small/abc.png",
        previewRemoteUrl: String? = nil
    ) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: original,
            previewUrl: URL(string: preview),
            previewRemoteUrl: previewRemoteUrl.flatMap(URL.init(string:)),
            meta: MediaAttachment.Meta(
                original: MediaAttachment.Size(width: 1_920, height: 1_080),
                small: MediaAttachment.Size(width: 640, height: 360)
            )
        )
    }

    /// 動画から作ったプレビューでは足りなければ、元の動画の先頭から最初のフレームを作る。作れなければプレビューを読む。
    @Test func videoAndGifReadTheFirstFrameWhenThePreviewIsTooSmall() throws {
        for type in [MediaAttachment.Kind.video, .gifv] {
            let attachment = video(type)
            let request = try #require(request(attachment))
            #expect(request.url == original)
            #expect(request.source == .videoFrame(fallback: try #require(attachment.previewUrl)))
        }
    }

    /// サーバーがファイルを消した他のサーバーの投稿では、プレビューが`media_proxy`を通る。作者がサムネイルを付けていなければ、動画から作ったもの。
    @Test func mediaProxyPreviewWithoutRemoteThumbnailIsGeneratedFromTheVideo() {
        #expect(request(video(preview: "https://example.social/media_proxy/123/small"))?.source != .image)
    }

    /// 作者が付けたサムネイルは差し替えない。他のサーバーの投稿では`previewRemoteUrl`が入り、自分のサーバーの投稿ではプレビューが`thumbnails/…/original/…`になる。
    @Test func authorThumbnailIsKept() {
        let remote = video(previewRemoteUrl: "https://other.example/media_attachments/thumbnails/1/original/thumb.png")
        #expect(request(remote)?.url == remote.previewUrl)
        #expect(request(remote)?.source == .image)

        let local = video(preview: "https://files.example.social/media_attachments/thumbnails/111/222/333/original/thumb.png")
        #expect(request(local)?.url == local.previewUrl)

        let proxied = video(preview: "https://example.social/media_proxy/123/small", previewRemoteUrl: "https://other.example/thumb.png")
        #expect(request(proxied)?.source == .image)
    }

    /// 動画から作ったか分からないプレビューは差し替えない。`small`はパスの区切りとして見る。
    @Test func unknownPreviewIsKept() {
        #expect(request(video(preview: "https://example.com/small.png"))?.source == .image)
        #expect(request(video(preview: "https://example.com/smaller/abc.png"))?.source == .image)
    }

    @Test func videoReadsPreviewWhenOriginalIsNotAllowed() {
        let policy = MediaThumbnailPolicy(allowsOriginal: false, upscaleTolerance: 1)
        #expect(request(video(), policy: policy)?.source == .image)
    }

    @Test func videoReadsPreviewWhenItCoversTheTile() {
        #expect(request(video(), tile: CGSize(width: 160, height: 90), scale: 3)?.source == .image)
    }

    @Test func audioAndUnknownKindsHaveNoThumbnail() {
        #expect(request(attachment(.audio)) == nil)
        #expect(request(attachment(.unknown("pdf"))) == nil)
    }

    /// 縦長の画像は上下を切り落として枠の幅を埋めるため、枠より高い画像が要る。
    /// 長い辺を枠の大きさで決め打ちすると、幅が足りずにぼやける。
    @Test func requiredSizeCoversTheTileWhenCropped() {
        let size = MediaThumbnailSelection.requiredPixelSize(
            tileSize: CGSize(width: 340, height: 340 / 0.75),
            displayScale: 3,
            aspectRatio: 9.0 / 16.0
        )
        #expect(size.width == 1_020)
        #expect(abs(size.height - 1_020 * 16 / 9) < 0.001)

        let tall = attachment(original: (1_080, 1_920), small: (360, 640))
        let request = request(tall, tile: CGSize(width: 340, height: 340 / 0.75))
        #expect(request?.url == original)
        #expect(request?.maxPixelSize == 2_048)
    }

    /// 横長の画像を縦長の枠に出すときは、左右を切り落として高さを埋める。
    @Test func requiredSizeCoversTheHeightOfANarrowTile() {
        let size = MediaThumbnailSelection.requiredPixelSize(tileSize: CGSize(width: 100, height: 200), displayScale: 2, aspectRatio: 2)
        #expect(size == CGSize(width: 800, height: 400))
    }

    @Test func requiredSizeFallsBackToTheTileWhenAspectRatioIsUnknown() {
        let size = MediaThumbnailSelection.requiredPixelSize(tileSize: CGSize(width: 100, height: 50), displayScale: 3, aspectRatio: nil)
        #expect(size == CGSize(width: 300, height: 150))
    }

    /// 枠の大きさが少し変わっても、同じ大きさで展開したキャッシュを使えるよう刻みで切り上げる。
    @Test func maxPixelSizeIsRoundedUpToSteps() {
        #expect(request(attachment(), tile: CGSize(width: 340, height: 191.25))?.maxPixelSize == 1_024)
        #expect(request(attachment(), tile: CGSize(width: 342, height: 192.375))?.maxPixelSize == 1_280)
        #expect(request(attachment(), tile: CGSize(width: 10_000, height: 5_625))?.maxPixelSize == 4_096)
    }

    @Test func originalIsNotAllowedInLowDataModeRegardlessOfSetting() {
        let lowData = NetworkConditions(isConstrained: true, isExpensive: false)
        #expect(!MediaThumbnailSelection.allowsOriginal(on: lowData, usesOriginalOnExpensiveNetwork: true))
        let lowDataOnCellular = NetworkConditions(isConstrained: true, isExpensive: true)
        #expect(!MediaThumbnailSelection.allowsOriginal(on: lowDataOnCellular, usesOriginalOnExpensiveNetwork: true))
    }

    @Test func expensiveNetworkFollowsTheSetting() {
        let cellular = NetworkConditions(isConstrained: false, isExpensive: true)
        #expect(MediaThumbnailSelection.allowsOriginal(on: cellular, usesOriginalOnExpensiveNetwork: true))
        #expect(!MediaThumbnailSelection.allowsOriginal(on: cellular, usesOriginalOnExpensiveNetwork: false))
    }

    /// Wi-Fiでは、モバイル通信の設定をオフにしていても元の画像を読む。
    @Test func unmeteredNetworkIgnoresTheSetting() {
        let wifi = NetworkConditions(isConstrained: false, isExpensive: false)
        #expect(MediaThumbnailSelection.allowsOriginal(on: wifi, usesOriginalOnExpensiveNetwork: false))
    }
}
