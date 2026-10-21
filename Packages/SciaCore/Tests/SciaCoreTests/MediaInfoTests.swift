import Foundation
import Testing
@testable import SciaCore

struct MediaInfoTests {
    private func decodeFixture() throws -> Status {
        let url = try #require(Bundle.module.url(forResource: "status_with_media", withExtension: "json", subdirectory: "Fixtures"))
        return try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))
    }

    private func values(_ info: MediaInfo) -> [String] {
        info.lines.map { "\($0.label): \($0.value)" }
    }

    /// 画像は解像度と形式だけ。拡張子のjpgはJPEGと書く。
    @Test func imageShowsResolutionAndFormat() throws {
        let image = try decodeFixture().mediaAttachments[0]

        #expect(values(MediaInfo(image)) == ["解像度: 640×480", "形式: JPEG"])
    }

    /// 動画は`meta.original`のフレームレート、長さ、ビットレートも並べる。分数のフレームレートは小数第2位までにする。
    @Test func videoShowsFrameRateDurationAndBitrate() throws {
        let video = try decodeFixture().mediaAttachments[1]

        #expect(values(MediaInfo(video)) == ["解像度: 1280×720", "形式: MP4", "フレームレート: 24.71 fps", "長さ: 1:28", "ビットレート: 862.06 kbps"])
    }

    /// 音声には大きさがない。
    @Test func audioShowsDurationAndBitrateWithoutResolution() throws {
        let audio = try decodeFixture().mediaAttachments[2]

        #expect(values(MediaInfo(audio)) == ["形式: MP3", "長さ: 6:42", "ビットレート: 166.29 kbps"])
    }

    /// 情報として見せるだけの値の型が違っても、添付ファイルごと読めなくしない。
    @Test func mismatchedTypesOfInformationalValuesDecodeAsNil() throws {
        let json = #"{"width": 600, "height": 332, "frame_rate": 30, "duration": "1.5", "bitrate": "fast"}"#
        let size = try MastodonDecoder.make().decode(MediaAttachment.Size.self, from: Data(json.utf8))

        #expect(size.width == 600)
        #expect(size.frameRate == nil)
        #expect(size.duration == nil)
        #expect(size.bitrate == nil)
    }

    /// 秒数を整数にして書くため、極端に大きな長さは出さない。整数にできずに落ちないようにする。
    @Test func omitsAbsurdDuration() {
        let attachment = MediaAttachment(
            id: "1", type: .video, url: nil, previewUrl: nil,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: nil, height: nil, duration: 1e300))
        )

        #expect(MediaInfo(attachment).lines.isEmpty)
    }

    /// ビューアでファイルの中身を読めたら、その値を優先し、ファイルの大きさや色などの行を足す。
    @Test func fileDetailsAddLinesAndOverrideMeta() throws {
        let image = try decodeFixture().mediaAttachments[0]
        var details = MediaFileDetails()
        details.pixelWidth = 1280
        details.pixelHeight = 960
        details.format = "HEIC"
        details.byteCount = 1_234_567
        details.colorProfile = "Display P3"
        details.bitDepth = 10
        details.dynamicRange = .gainMap
        details.hasAlpha = true

        #expect(values(MediaInfo(image, details: details)) == [
            "解像度: 1280×960",
            "形式: HEIC",
            "ファイルの大きさ: 1.23 MB",
            "カラープロファイル: Display P3",
            "ビット深度: 10 bit",
            "ダイナミックレンジ: HDR（ゲインマップ）",
            "アルファチャンネル: あり",
        ])
    }

    /// 動画は、映像のコーデックと音声を足す。長さとビットレートは`meta`から読む。
    @Test func videoDetailsAddCodecsAndAudio() throws {
        let video = try decodeFixture().mediaAttachments[1]
        var details = MediaFileDetails()
        details.videoCodec = "HEVC"
        details.frameRate = 30
        details.dynamicRange = .hlg
        details.audio = MediaFileDetails.Audio.none

        #expect(values(MediaInfo(video, details: details)) == [
            "解像度: 1280×720",
            "形式: MP4",
            "ダイナミックレンジ: HDR（HLG）",
            "映像のコーデック: HEVC",
            "フレームレート: 30 fps",
            "長さ: 1:28",
            "ビットレート: 862.06 kbps",
            "音声: なし",
        ])
    }

    /// ファイルに撮影の情報があれば、撮影日時、カメラ、レンズ、露出、位置を足す。
    @Test func captureDetailsAddLines() throws {
        let image = try decodeFixture().mediaAttachments[0]
        var details = MediaFileDetails()
        details.capture.date = "2024:05:01 12:34:56"
        details.capture.camera = "Apple iPhone 16 Pro"
        details.capture.fNumber = 1.78
        details.capture.exposureTime = 1.0 / 120
        details.capture.iso = 80
        details.capture.focalLength = 26
        details.capture.latitude = 35.6812
        details.capture.longitude = -139.7671

        #expect(Array(values(MediaInfo(image, details: details)).suffix(7)) == [
            "撮影日時: 2024/05/01 12:34:56",
            "カメラ: Apple iPhone 16 Pro",
            "絞り: f/1.78",
            "シャッター速度: 1/120 s",
            "ISO感度: 80",
            "焦点距離: 26 mm",
            "撮影場所: 35.68120, -139.76710",
        ])
    }

    @Test func writesExposureTimes() {
        #expect(MediaInfo.exposureText(1.0 / 250) == "1/250 s")
        #expect(MediaInfo.exposureText(2.5) == "2.5 s")
        #expect(MediaInfo.exposureText(1.0 / 3) == "1/3 s")
        // 逆数が整数にならない値は、丸めて別の値にせず秒数で書く。
        #expect(MediaInfo.exposureText(0.8) == "0.8 s")
        #expect(MediaInfo.exposureText(0.6) == "0.6 s")
        // 分母を整数にできない極端な値は、落ちずに出さない。
        #expect(MediaInfo.exposureText(1e-300) == nil)
        #expect(MediaInfo.exposureText(1e300) == nil)
        #expect(MediaInfo.captureDateText("不明") == "不明")
    }

    @Test func writesByteCountsInReadableUnits() {
        #expect(MediaInfo.byteCountText(512) == "512 B")
        #expect(MediaInfo.byteCountText(45_600) == "45.6 KB")
        #expect(MediaInfo.byteCountText(2_000_000_000) == "2 GB")
    }

    @Test func parsesFrameRates() {
        #expect(MediaInfo.framesPerSecond("30") == 30)
        #expect(MediaInfo.framesPerSecond("100/3").map { ($0 * 100).rounded() } == 3333)
        #expect(MediaInfo.framesPerSecond("30/0") == nil)
        #expect(MediaInfo.framesPerSecond("0/1") == nil)
        #expect(MediaInfo.framesPerSecond("abc") == nil)
        #expect(MediaInfo.framesPerSecond("1/2/3") == nil)
    }

    @Test func writesBitratesInReadableUnits() {
        #expect(MediaInfo.bitrateText(800) == "800 bps")
        #expect(MediaInfo.bitrateText(128_000) == "128 kbps")
        #expect(MediaInfo.bitrateText(1_627_639) == "1.63 Mbps")
    }

    /// 拡張子のないURLやURLのない添付ファイルでは、形式を出さない。
    @Test func omitsFormatWithoutExtension() {
        let attachment = MediaAttachment(id: "1", type: .image, url: URL(string: "https://example.com/media/abc"), previewUrl: nil)

        #expect(MediaInfo(attachment).lines.isEmpty)
    }
}
