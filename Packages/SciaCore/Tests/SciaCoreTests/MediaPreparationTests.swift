import Foundation
import Testing
@testable import SciaCore

struct MediaPreparationTests {
    private let mastodonLimits = MediaLimits(
        imageSizeLimit: 16_777_216,
        imageMatrixLimit: 33_177_600,
        videoSizeLimit: 103_809_024,
        videoMatrixLimit: 8_294_400,
        videoFrameRateLimit: 120
    )
    private let supported = ["image/jpeg", "image/png", "image/gif", "image/heic", "video/mp4"]
    private let quality = VideoPlan.Quality(bitRate1080p: 8_000_000, minimumBitRate1080p: 1_000_000, sizeLimitMargin: 0.95, audioBitRate: 128_000)

    private func imagePlan(
        _ width: Int, _ height: Int,
        bytes: Int = 3_000_000,
        mimeType: String = "image/heic",
        setting: ImageUploadSize = .long4096,
        limits: MediaLimits? = nil,
        unprocessable: Set<String> = []
    ) -> ImagePlan? {
        ImagePlan.make(
            size: PixelSize(width: width, height: height),
            byteCount: bytes,
            mimeType: mimeType,
            setting: setting,
            limits: limits ?? mastodonLimits,
            supportedMIMETypes: supported,
            unprocessableMIMETypes: unprocessable
        )
    }

    // MARK: - 画像

    /// iPhoneの標準の写真（12MP）は長辺4096pxに収まるので、作り直さずに元のまま送る。
    @Test func sendsTypicalPhotoAsIs() {
        #expect(imagePlan(4032, 3024) == nil)
    }

    /// 縮めないを選んでいて、上限にも収まれば、大きな写真も元のまま送る。
    @Test func originalSettingKeepsLargePhoto() {
        #expect(imagePlan(5712, 4284, setting: .original) == nil)
    }

    /// 縮めないを選んでいても、サーバーの画素数の上限（33MP）を超える48MPの写真は縮める。
    @Test func originalSettingStillFitsTheMatrixLimit() throws {
        let plan = try #require(imagePlan(8064, 6048, setting: .original))
        #expect(plan.size.pixels <= 33_177_600)
        #expect(plan.sizeBySetting == PixelSize(width: 8064, height: 6048))
    }

    /// 48MPの写真は、縦横比を保って長辺4096pxに縮め、サーバーが受け付けるHEICで作り直す。
    @Test func shrinksLargePhotoToTheChosenLongSide() throws {
        let plan = try #require(imagePlan(8064, 6048))
        #expect(plan.size == PixelSize(width: 4096, height: 3072))
        #expect(plan.sizeBySetting == plan.size)
        #expect(plan.mimeType == "image/heic")
    }

    /// サーバーの画素数の上限は、設定の大きさよりさらに小さくすることがある。
    @Test func fitsTheServerMatrixLimit() throws {
        var limits = mastodonLimits
        limits.imageMatrixLimit = 4_000_000
        let plan = try #require(imagePlan(4032, 3024, limits: limits))
        #expect(plan.size.pixels <= 4_000_000)
        #expect(plan.sizeBySetting == PixelSize(width: 4032, height: 3024))
    }

    /// 解像度は収まっていて容量だけが超えるときも、作り直す。
    @Test func reencodesWhenOnlyTheByteCountExceeds() throws {
        let plan = try #require(imagePlan(4032, 3024, bytes: 20_000_000))
        #expect(plan.exceedsSizeLimit)
        #expect(plan.size == PixelSize(width: 4032, height: 3024))
    }

    /// 上限を返さないサーバーでは、推測で縮めない。
    @Test func unknownLimitsDoNotShrink() {
        #expect(imagePlan(4032, 3024, bytes: 50_000_000, setting: .original, limits: .unknown) == nil)
    }

    @Test func keepsPNGAsPNG() throws {
        let plan = try #require(imagePlan(6000, 3000, mimeType: "image/png"))
        #expect(plan.mimeType == "image/png")
    }

    /// 処理できないと分かったHEICは使わず、JPEGで作り直す。
    @Test func avoidsUnprocessableHEIC() throws {
        let plan = try #require(imagePlan(8064, 6048, unprocessable: ["image/heic"]))
        #expect(plan.mimeType == "image/jpeg")
    }

    /// 処理できないと分かった形式は、大きさが収まっていても、同じ大きさのJPEGで作り直す。
    /// ペーストしたものは、ピッカーのように同じ写真のJPEGを受け取り直せないため。
    @Test func reencodesUnprocessableFormatEvenWhenItFits() throws {
        let plan = try #require(imagePlan(4032, 3024, unprocessable: ["image/heic"]))
        #expect(plan.mimeType == "image/jpeg")
        #expect(plan.size == PixelSize(width: 4032, height: 3024))
        #expect(plan.sizeBySetting == plan.size)
    }

    /// アニメーションを保ったまま縮められないので、GIFは作り直さない。
    @Test func leavesGIFAlone() {
        #expect(imagePlan(8000, 8000, mimeType: "image/gif") == nil)
    }

    // MARK: - 動画

    private func videoPlan(
        _ width: Int, _ height: Int,
        duration: Double = 30,
        frameRate: Double = 30,
        bytes: Int = 50_000_000,
        setting: VideoUploadSize = .p1080,
        limits: MediaLimits? = nil,
        hasAudio: Bool = true
    ) -> VideoPlan {
        VideoPlan.make(
            size: PixelSize(width: width, height: height),
            duration: duration,
            frameRate: frameRate,
            hasAudio: hasAudio,
            byteCount: bytes,
            setting: setting,
            limits: limits ?? mastodonLimits,
            quality: quality
        )
    }

    /// iPhoneの標準の撮影設定（1080p）の動画は、元のまま送る。
    @Test func sendsTypical1080pVideoAsIs() {
        #expect(videoPlan(1920, 1080) == .original)
        #expect(videoPlan(1080, 1920) == .original)
    }

    /// 4Kの動画は、短辺1080に縮めて、設定どおりのビットレートで書き出す。設定で選んだ変化なので知らせない。
    @Test func shrinks4KVideoToTheChosenSize() {
        #expect(videoPlan(3840, 2160, bytes: 90_000_000) == .export(size: PixelSize(width: 1920, height: 1080), frameRate: nil, bitRate: 8_000_000, reducedByServer: false))
    }

    /// 容量の上限を超える長い動画は、長さから上限に収まるビットレートに下げ、サーバーのために下げたと知らせる。
    @Test func lowersBitRateToFitTheSizeLimit() throws {
        guard case .export(let size, _, let bitRate, let reduced) = videoPlan(1920, 1080, duration: 300, bytes: 300_000_000) else {
            Issue.record("書き出すはず")
            return
        }
        #expect(size == PixelSize(width: 1920, height: 1080))
        #expect(bitRate < 8_000_000)
        #expect(bitRate >= 1_000_000)
        #expect(reduced)
        // 音声の分と余裕を見込んで、上限に収まる。
        #expect(Double(bitRate + 128_000) * 300 / 8 <= 103_809_024)
    }

    /// ビットレートが下限を割るほど長ければ、解像度を下げる。
    @Test func lowersResolutionWhenBitRateWouldBeTooLow() throws {
        guard case .export(let size, _, let bitRate, let reduced) = videoPlan(1920, 1080, duration: 1200, bytes: 1_000_000_000) else {
            Issue.record("書き出すはず")
            return
        }
        #expect(size.shortSide < 1080)
        #expect(bitRate >= quality.minimumBitRate(for: size))
        #expect(reduced)
    }

    /// 解像度を下げても見られる画質にならないほど長い動画は、縮めずに失敗させる。
    @Test func refusesVideoTooLongToFit() {
        #expect(videoPlan(1920, 1080, duration: 3 * 3600, bytes: 5_000_000_000) == .tooLong)
    }

    /// 縮めないを選んでいても、容量の上限を超えれば、元の解像度のまま収める。
    @Test func originalSettingStillFitsTheSizeLimit() throws {
        guard case .export(let size, _, _, let reduced) = videoPlan(1920, 1080, duration: 300, bytes: 300_000_000, setting: .original) else {
            Issue.record("書き出すはず")
            return
        }
        #expect(size == PixelSize(width: 1920, height: 1080))
        #expect(reduced)
    }

    /// 音声のない動画は、音声の分を引かずに、映像に容量を回す。
    @Test func silentVideoUsesTheWholeBudgetForVideo() {
        var limits = mastodonLimits
        limits.videoSizeLimit = 5_000_000
        guard case .export(let size, _, let bitRate, _) = videoPlan(1920, 1080, duration: 180, bytes: 50_000_000, limits: limits, hasAudio: false) else {
            Issue.record("書き出すはず")
            return
        }
        // 5MBを180秒に配ると約211kbpsで、短辺360の下限（約111kbps）より高いので収まる。
        #expect(bitRate > 200_000)
        #expect(size.shortSide >= 360)
    }

    /// 0.75倍ずつ縮めて短辺360を飛び越しても、短辺360で収まるなら、失敗させずに360で書き出す。
    @Test func triesTheMinimumShortSideBeforeGivingUp() {
        var limits = mastodonLimits
        limits.videoSizeLimit = 7_000_000
        guard case .export(let size, _, _, _) = videoPlan(1920, 1080, duration: 180, bytes: 50_000_000, limits: limits) else {
            Issue.record("短辺360なら収まるはず")
            return
        }
        #expect(size.shortSide == 360)
    }

    @Test func capsTheFrameRate() {
        var limits = mastodonLimits
        limits.videoFrameRateLimit = 60
        #expect(videoPlan(1920, 1080, frameRate: 120, limits: limits) == .export(size: PixelSize(width: 1920, height: 1080), frameRate: 60, bitRate: 8_000_000, reducedByServer: true))
    }

    /// H.264は幅と高さが偶数でないと書き出せない。
    @Test func keepsVideoSidesEven() {
        guard case .export(let size, _, _, _) = videoPlan(3841, 2161, bytes: 90_000_000) else {
            Issue.record("書き出すはず")
            return
        }
        #expect(size.width.isMultiple(of: 2))
        #expect(size.height.isMultiple(of: 2))
    }
}
