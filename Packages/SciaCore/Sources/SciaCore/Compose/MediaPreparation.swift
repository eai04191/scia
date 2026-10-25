import Foundation

/// サーバーが受け付けるメディアの大きさの上限。`/api/v2/instance`の`configuration.media_attachments`の値。
/// サーバーは上限を変えていることが多いので、返さない項目はnilのままにし、Mastodonの既定値で補わない。
public struct MediaLimits: Sendable, Equatable {
    /// 画像の容量（バイト）。
    public var imageSizeLimit: Int?
    /// 画像の画素数（幅×高さ）。
    public var imageMatrixLimit: Int?
    /// 動画の容量（バイト）。
    public var videoSizeLimit: Int?
    /// 動画の画素数（幅×高さ）。
    public var videoMatrixLimit: Int?
    /// 動画のフレームレート。
    public var videoFrameRateLimit: Int?

    public init(imageSizeLimit: Int?, imageMatrixLimit: Int?, videoSizeLimit: Int?, videoMatrixLimit: Int?, videoFrameRateLimit: Int?) {
        self.imageSizeLimit = imageSizeLimit
        self.imageMatrixLimit = imageMatrixLimit
        self.videoSizeLimit = videoSizeLimit
        self.videoMatrixLimit = videoMatrixLimit
        self.videoFrameRateLimit = videoFrameRateLimit
    }

    /// 上限が分からないサーバー。
    public static let unknown = MediaLimits(imageSizeLimit: nil, imageMatrixLimit: nil, videoSizeLimit: nil, videoMatrixLimit: nil, videoFrameRateLimit: nil)
}

/// 画像と動画の幅と高さ（画素）。向きを反映した、見えるとおりの値。
public struct PixelSize: Sendable, Equatable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixels: Int { width * height }
    public var longSide: Int { max(width, height) }
    public var shortSide: Int { min(width, height) }
    public var description: String { "\(width)×\(height)" }

    /// 縦横比を保って`scale`倍にする。1より大きくはしない。H.264は幅と高さが偶数でないと書き出せないので、`even`なら偶数に切り捨てる。
    func scaled(by scale: Double, even: Bool = false) -> PixelSize {
        guard scale < 1 else { return self }
        func side(_ length: Int) -> Int {
            let scaled = max(Int((Double(length) * scale).rounded(.down)), even ? 2 : 1)
            return even ? scaled - scaled % 2 : scaled
        }
        return PixelSize(width: side(width), height: side(height))
    }

    /// 画素数が`limit`以下になるよう縮める。
    func fitting(pixels limit: Int?, even: Bool = false) -> PixelSize {
        guard let limit, pixels > limit else { return self }
        return scaled(by: (Double(limit) / Double(pixels)).squareRoot(), even: even)
    }
}

/// 送る前に画像を縮める大きさ。使う人が設定で選ぶ。
public enum ImageUploadSize: String, Sendable, CaseIterable {
    case original
    case long4096
    case long2048

    /// 長辺の上限。縮めないならnil。
    public var maxLongSide: Int? {
        switch self {
        case .original: nil
        case .long4096: 4096
        case .long2048: 2048
        }
    }

    public var title: String {
        switch self {
        case .original: "縮めない"
        case .long4096: "長辺4096px"
        case .long2048: "長辺2048px"
        }
    }
}

/// 送る前に動画を縮める大きさ。使う人が設定で選ぶ。
public enum VideoUploadSize: String, Sendable, CaseIterable {
    case original
    case p1080
    case p720

    /// 短辺の上限。縮めないならnil。
    public var maxShortSide: Int? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        }
    }

    public var title: String {
        switch self {
        case .original: "縮めない"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
}

/// 画像をどう作り直すか。
public struct ImagePlan: Sendable, Equatable {
    /// 作り直す形式のMIMEタイプ。
    public let mimeType: String
    /// 設定の大きさとサーバーの画素数の上限に収めた大きさ。容量の上限を超えたら、作り直しながらさらに縮める。
    public let size: PixelSize
    /// 設定の大きさだけに収めた大きさ。これより小さくなったら、サーバーの上限のために縮めたと知らせる。
    public let sizeBySetting: PixelSize
    /// 大きさを変えなくても、容量の上限を超えているので作り直す。
    public let exceedsSizeLimit: Bool

    public init(mimeType: String, size: PixelSize, sizeBySetting: PixelSize, exceedsSizeLimit: Bool) {
        self.mimeType = mimeType
        self.size = size
        self.sizeBySetting = sizeBySetting
        self.exceedsSizeLimit = exceedsSizeLimit
    }

    /// 元の画像から作り直す必要があるか。決めるには、元の大きさ、容量、形式が要る。
    /// 選んだ大きさに収まり、サーバーの上限にも収まる画像は、作り直さず元のまま送る。iPhoneのHEICは作り直してもほとんど小さくならず、画質だけが落ちるため。
    /// ただし処理できないと分かった形式は、収まっていても同じ大きさで作り直す。ペーストしたものは、ピッカーのように同じ写真のJPEGを受け取り直せないため。
    /// - Parameters:
    ///   - supportedMIMETypes: サーバーが受け付けると返した形式。返さないサーバーではnil。
    ///   - unprocessableMIMETypes: 受け付けると返しながら、処理できなかった形式。
    ///   - cropping: 切り抜いて送る。中身が変わるので、収まっていても作り直す。`size`には切り抜いたあとの大きさを、`byteCount`には元の容量を渡す。
    ///     切り抜いたあとの容量は作り直すまで分からないため、容量の上限は作り直しながら確かめ、`exceedsSizeLimit`にはしない。
    /// - Returns: 元のまま送るならnil。
    public static func make(
        size: PixelSize,
        byteCount: Int,
        mimeType: String,
        setting: ImageUploadSize,
        limits: MediaLimits,
        supportedMIMETypes: [String]?,
        unprocessableMIMETypes: Set<String>,
        cropping: Bool = false
    ) -> ImagePlan? {
        // アニメーションを保ったまま縮められないので、GIFは作り直さない。
        guard mimeType != "image/gif" else { return nil }
        let bySetting = setting.maxLongSide.map { size.scaled(by: Double($0) / Double(size.longSide)) } ?? size
        let target = bySetting.fitting(pixels: limits.imageMatrixLimit)
        let exceedsSizeLimit = !cropping && (limits.imageSizeLimit.map { byteCount > $0 } ?? false)
        guard cropping || target != size || exceedsSizeLimit || unprocessableMIMETypes.contains(mimeType) else { return nil }
        return ImagePlan(
            mimeType: outputMIMEType(for: mimeType, supported: supportedMIMETypes, unprocessable: unprocessableMIMETypes),
            size: target,
            sizeBySetting: bySetting,
            exceedsSizeLimit: exceedsSizeLimit
        )
    }

    /// 作り直す形式。元がPNGならPNGのまま縮める。JPEGにすると、スクリーンショットの文字がにじみ、透過も消えるため。
    /// それ以外は、サーバーが受け付けると返していて、処理できないと分かっていなければHEIC、そうでなければJPEGにする。
    /// AVIFは、iOSの書き出しではHEICとほぼ同じ大きさにしかならず、時間は数倍かかるので使わない。
    static func outputMIMEType(for mimeType: String, supported: [String]?, unprocessable: Set<String>) -> String {
        if mimeType == "image/png" { return "image/png" }
        let heic = "image/heic"
        if supported?.contains(heic) == true, !unprocessable.contains(heic) { return heic }
        return "image/jpeg"
    }
}

/// 動画をどう書き出すか。
public enum VideoPlan: Sendable, Equatable {
    /// 元のまま送る。
    case original
    /// H.264で書き出す。
    /// - frameRate: 上限に合わせて落とすフレームレート。落とさないならnil。
    /// - reducedByServer: 設定で選んだ大きさより、サーバーの上限のために小さく、または低い画質にした。
    case export(size: PixelSize, frameRate: Double?, bitRate: Int, reducedByServer: Bool)
    /// 解像度を下げても見られる画質にならず、サーバーの容量の上限に収められない。
    case tooLong

    /// 書き出しの好みの値。チューニングで決める。
    public struct Quality: Sendable, Equatable {
        /// 1920×1080で書き出すときのビットレート（bps）。ほかの大きさでは画素数に比例させる。
        public var bitRate1080p: Int
        /// 見られる画質の下限の、1920×1080のときのビットレート（bps）。ほかの大きさでは画素数に比例させる。
        public var minimumBitRate1080p: Int
        /// 容量の上限に収めるとき、上限のどれだけまでを使うか。書き出したあとに上限を超えないよう、余裕を残す。
        public var sizeLimitMargin: Double
        /// 音声のビットレート（bps）。容量の計算で、動画の分から引く。
        public var audioBitRate: Int

        public init(bitRate1080p: Int, minimumBitRate1080p: Int, sizeLimitMargin: Double, audioBitRate: Int) {
            self.bitRate1080p = bitRate1080p
            self.minimumBitRate1080p = minimumBitRate1080p
            self.sizeLimitMargin = sizeLimitMargin
            self.audioBitRate = audioBitRate
        }

        func bitRate(for size: PixelSize) -> Int {
            Int(Double(bitRate1080p) * Double(size.pixels) / Self.pixels1080p)
        }

        func minimumBitRate(for size: PixelSize) -> Int {
            Int(Double(minimumBitRate1080p) * Double(size.pixels) / Self.pixels1080p)
        }

        private static let pixels1080p = Double(1920 * 1080)
    }

    /// 元の動画から書き出す必要があるかを決める。
    /// 選んだ大きさに収まり、サーバーの上限にも収まる動画は、元のまま送る。
    /// 容量の上限を超えるときは、長さから上限に収まるビットレートで書き出し、それが下限より低いときは解像度を下げる。動画の長さは保ち、後ろを切らない。
    /// - Parameter hasAudio: 音声がある。ないなら、音声の分を引かずに容量を映像に回す。書き出す側も、音声がなければ音声を書かない。
    public static func make(
        size: PixelSize,
        duration: Double,
        frameRate: Double,
        hasAudio: Bool,
        byteCount: Int,
        setting: VideoUploadSize,
        limits: MediaLimits,
        quality: Quality
    ) -> VideoPlan {
        let bySetting = setting.maxShortSide.map { size.scaled(by: Double($0) / Double(size.shortSide), even: true) } ?? size
        var target = bySetting.fitting(pixels: limits.videoMatrixLimit, even: true)
        let cappedFrameRate = limits.videoFrameRateLimit.flatMap { frameRate > Double($0) ? Double($0) : nil }
        let exceedsSizeLimit = limits.videoSizeLimit.map { byteCount > $0 } ?? false
        guard target != size || cappedFrameRate != nil || exceedsSizeLimit else { return .original }
        var bitRate = quality.bitRate(for: target)
        if let sizeLimit = limits.videoSizeLimit, duration > 0 {
            // 容量の上限が大きく動画が短いと、整数に収まらない。どの画質のビットレートも上回る大きさ（Int32の上限、約2Gbps）で止める。
            let available = Int(min(Double(sizeLimit) * quality.sizeLimitMargin * 8 / duration, Double(Int32.max))) - (hasAudio ? quality.audioBitRate : 0)
            while available < bitRate {
                if available >= quality.minimumBitRate(for: target) {
                    bitRate = available
                    break
                }
                // 下限を割るなら、解像度を下げて、その大きさの下限と比べ直す。0.75倍で短辺の下限を飛び越すときは、下限ちょうどで最後に比べる。
                guard target.shortSide > minimumShortSide else { return .tooLong }
                var smaller = target.scaled(by: 0.75, even: true)
                if smaller.shortSide < minimumShortSide {
                    smaller = target.scaled(by: Double(minimumShortSide) / Double(target.shortSide), even: true)
                }
                guard smaller != target else { return .tooLong }
                target = smaller
                bitRate = quality.bitRate(for: target)
            }
        }
        // 設定で選んだ大きさのとおりに書き出すときだけ、使う人が選んだ変化とみなす。それ以外は、サーバーの上限のために変えた。
        let matchesSetting = bySetting != size && target == bySetting && cappedFrameRate == nil && bitRate == quality.bitRate(for: target)
        return .export(size: target, frameRate: cappedFrameRate, bitRate: bitRate, reducedByServer: !matchesSetting)
    }

    /// これより短辺を小さくしても見られる画質にはならないので、収められないとする。
    static let minimumShortSide = 360
}
