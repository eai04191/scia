public import Foundation
public import Observation

/// 「接続の状態」画面に出す、セッションの接続の状態を集める。セッションごとに1つ持つ。
@MainActor
@Observable
public final class ConnectionDiagnostics {
    public enum StreamingState: Sendable, Equatable {
        case connected
        /// つなぎ始めた、または切れてつなぎ直している。切れていると知らせるまでの短い間。
        case connecting
        /// つながらない状態が続いている。つなぎ直しを続けながら、ポーリングでRESTから新着を読んでいる。
        case polling
        /// バックグラウンドやログアウトで、つなぐのを止めている。
        case stopped
        /// トークンが無効になり、ログインし直すまでつなぐのを止めている。
        case loginRequired
    }

    /// サーバーが返した版。まだ読めていなければnil。
    public private(set) var serverVersion: String?
    /// ストリーミングの接続の状態。まだつなぎ始めていなければnil。
    public private(set) var streaming: StreamingState?
    /// その接続で購読しているストリーム。
    public private(set) var streamingSubscriptions: [StreamingSubscription] = []
    @ObservationIgnored private let rateLimit: RateLimitGate
    @ObservationIgnored private let features: FeatureAvailability
    @ObservationIgnored private let requestLog: RequestLog
    /// サーバーが処理できなかったので、送るのをやめた画像の形式。
    public let mediaFormats: UnprocessableMediaFormats

    public init(rateLimit: RateLimitGate, features: FeatureAvailability, requestLog: RequestLog, mediaFormats: UnprocessableMediaFormats) {
        self.rateLimit = rateLimit
        self.features = features
        self.requestLog = requestLog
        self.mediaFormats = mediaFormats
    }

    public func setServerVersion(_ version: String) {
        serverVersion = version
    }

    public func setStreaming(_ state: StreamingState, subscriptions: [StreamingSubscription]) {
        streaming = state
        streamingSubscriptions = subscriptions
    }

    /// 他の部品が持っている状態を、今の時点で集める。
    public func status() async -> Status {
        Status(
            pausedUntil: await rateLimit.pausedUntil,
            disabledFeatures: await features.disabled,
            recentFailures: requestLog.recentFailures,
            droppedCount: DecodingLog.droppedCount
        )
    }

    public struct Status: Sendable, Equatable {
        /// レート制限で、自動の通信を控えている間の再開の時刻。
        public let pausedUntil: Date?
        public let disabledFeatures: [FeatureAvailability.Disabled]
        /// 新しい順。
        public let recentFailures: [RequestFailure]
        /// この起動の間に、読めずに外したり、表示できない行にしたりした項目の数。
        public let droppedCount: Int
    }
}
