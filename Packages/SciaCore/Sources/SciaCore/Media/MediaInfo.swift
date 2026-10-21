import Foundation

/// メディアのメニューの「メディアの情報」に並べる行。決まりはdocs/menus.mdの「メディアのメニュー」にある。
/// 値はMastodonが添付ファイルに付ける`meta.original`から読み、形式はファイルのURLの拡張子から読む。
/// ビューアで開いてファイルの中身を読めたら、`details`の値を優先し、ファイルの大きさや色などの行を足す。
public struct MediaInfo: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// 分かるものだけを、見た目、ファイル、色、映像、時間、音声の順に並べる。
    public let lines: [Line]

    public init(_ attachment: MediaAttachment, details: MediaFileDetails? = nil) {
        let original = attachment.meta?.original
        var lines: [Line] = []
        func add(_ label: String, _ value: String?) {
            if let value { lines.append(Line(label: label, value: value)) }
        }
        let width = details?.pixelWidth ?? original?.width
        let height = details?.pixelHeight ?? original?.height
        if let width, let height, width > 0, height > 0 {
            add("解像度", "\(width)×\(height)")
        }
        add("形式", details?.format ?? Self.format(of: attachment.url ?? attachment.remoteUrl))
        add("ファイルの大きさ", details?.byteCount.flatMap { $0 > 0 ? Self.byteCountText($0) : nil })
        add("カラープロファイル", details?.colorProfile)
        add("ビット深度", details?.bitDepth.map { "\($0) bit" })
        add("ダイナミックレンジ", details?.dynamicRange.map(Self.dynamicRangeText(_:)))
        add("アルファチャンネル", details?.hasAlpha == true ? "あり" : nil)
        add("映像のコーデック", details?.videoCodec)
        let frameRate = details?.frameRate ?? original?.frameRate.flatMap(Self.framesPerSecond(_:))
        add("フレームレート", frameRate.map { "\(Self.decimal($0)) fps" })
        // 秒数は整数にして書くため、サーバーが極端に大きな値を返しても落ちないよう、100年未満に限る。
        if let duration = original?.duration, duration.isFinite, duration > 0, duration < Self.maximumDuration {
            add("長さ", PlaybackTime(elapsed: duration, duration: duration).elapsedText)
        }
        if let bitrate = original?.bitrate, bitrate > 0 {
            add("ビットレート", Self.bitrateText(bitrate))
        }
        switch details?.audio {
        case .none?: add("音声", "なし")
        case .codec(let codec)?: add("音声", codec)
        case nil: break
        }
        if let capture = details?.capture {
            add("撮影日時", capture.date.map(Self.captureDateText(_:)))
            add("カメラ", capture.camera)
            add("レンズ", capture.lens)
            add("絞り", capture.fNumber.map { "f/\(Self.decimal($0))" })
            add("シャッター速度", capture.exposureTime.flatMap(Self.exposureText(_:)))
            add("ISO感度", capture.iso.map { "\($0)" })
            add("焦点距離", capture.focalLength.map { "\(Self.decimal($0)) mm" })
            if let latitude = capture.latitude, let longitude = capture.longitude {
                add("撮影場所", "\(Self.coordinate(latitude)), \(Self.coordinate(longitude))")
            }
        }
        self.lines = lines
    }

    /// EXIFの`2024:05:01 12:34:56`を`2024/05/01 12:34:56`にする。形が違えばそのまま出す。
    static func captureDateText(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10 else { return text }
        return parts[0].replacingOccurrences(of: ":", with: "/") + " " + parts[1]
    }

    /// 逆数がほぼ整数（1%以内）なら`1/120 s`のように分数で、そうでなければ`0.8 s`のように秒数で書く。
    /// 0.8秒を`1/1 s`のように、丸めで別の値にしないため。分母を整数にして書くため、ファイルに極端な値が書かれていても落ちないよう、
    /// 100万分の1秒から1日までの値だけを出す。
    static func exposureText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1.0 / 1_000_000, seconds <= 24 * 3600 else { return nil }
        let denominator = 1 / seconds
        if seconds < 1, abs(denominator - denominator.rounded()) <= denominator * 0.01 {
            return "1/\(Int(denominator.rounded())) s"
        }
        return "\(decimal(seconds)) s"
    }

    private static func coordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(5)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    static func dynamicRangeText(_ range: MediaFileDetails.DynamicRange) -> String {
        switch range {
        case .standard: "SDR"
        case .gainMap: "HDR（ゲインマップ）"
        case .pq: "HDR（PQ）"
        case .hlg: "HDR（HLG）"
        }
    }

    /// Finderと同じく1000ごとに単位を上げる。
    static func byteCountText(_ bytes: Int) -> String {
        switch bytes {
        case ..<1000: "\(bytes) B"
        case ..<1_000_000: "\(decimal(Double(bytes) / 1000)) KB"
        case ..<1_000_000_000: "\(decimal(Double(bytes) / 1_000_000)) MB"
        default: "\(decimal(Double(bytes) / 1_000_000_000)) GB"
        }
    }

    /// 書く長さの上限の秒数。
    static let maximumDuration: Double = 100 * 365 * 24 * 3600

    /// 拡張子を大文字にしたもの。`jpg`は`JPEG`と書く。拡張子がなければnil。
    static func format(of url: URL?) -> String? {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return nil }
        return ext == "jpg" ? "JPEG" : ext.uppercased()
    }

    /// `"30000/1001"`のような分数か、`"30"`のような数の文字列を、毎秒のコマ数にする。読めなければnil。
    static func framesPerSecond(_ text: String) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let value: Double?
        switch parts.count {
        case 1:
            value = Double(parts[0])
        case 2:
            guard let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else { return nil }
            value = numerator / denominator
        default:
            value = nil
        }
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// 1000ビット毎秒より下はbps、100万より下はkbps、それより上はMbpsで書く。
    static func bitrateText(_ bitrate: Int) -> String {
        switch bitrate {
        case ..<1000: "\(bitrate) bps"
        case ..<1_000_000: "\(decimal(Double(bitrate) / 1000)) kbps"
        default: "\(decimal(Double(bitrate) / 1_000_000)) Mbps"
        }
    }

    /// 小数第2位までにし、末尾の0は書かない。
    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
