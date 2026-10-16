import Foundation

/// 動画の再生位置を、シークバーの両端に出す経過と残りの文字にする。
public struct PlaybackTime: Equatable, Sendable {
    /// 経過した秒数。長さを超えない。
    public let elapsed: Double
    /// 動画の長さの秒数。読み込む前などで分からなければ0。
    public let duration: Double

    /// 値がNaNや負、無限大のときは0として扱う。長さを読み込む前に来ることがあるため。
    public init(elapsed: Double, duration: Double) {
        let duration = Self.sanitized(duration)
        self.duration = duration
        self.elapsed = min(Self.sanitized(elapsed), duration)
    }

    /// 長さのうち再生した割合。0から1。
    public var progress: Double {
        duration > 0 ? elapsed / duration : 0
    }

    /// 経過。秒は切り捨てる。
    public var elapsedText: String {
        Self.format(Int(elapsed.rounded(.down)), withHours: usesHours)
    }

    /// 残り。経過と足して長さになるよう、秒は切り上げる。
    public var remainingText: String {
        "-" + Self.format(Int((duration - elapsed).rounded(.up)), withHours: usesHours)
    }

    /// 1時間を超える動画では、経過も残りも時間の桁を付けてそろえ、再生中に文字の幅が変わらないようにする。
    private var usesHours: Bool { duration >= 3600 }

    private static func format(_ seconds: Int, withHours: Bool) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        if withHours {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}
