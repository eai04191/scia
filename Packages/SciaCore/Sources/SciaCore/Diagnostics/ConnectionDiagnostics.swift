public import Foundation
public import Observation

/// 「接続の状態」画面に出す、セッションの接続の状態を集める。セッションごとに1つ持つ。
@MainActor
@Observable
public final class ConnectionDiagnostics {
    public enum Channel: Sendable, Hashable, CaseIterable {
        case home
        case notifications
    }

    public enum StreamingState: Sendable, Equatable {
        case connected
        /// つながっていない。つなぎ直しを続けながら、定期的にRESTで新着を読んでいる。
        case polling
        /// バックグラウンドなどで、つなぐのを止めている。
        case stopped
    }

    /// サーバーが返した版。まだ読めていなければnil。
    public private(set) var serverVersion: String?
    public private(set) var streaming: [Channel: StreamingState] = [:]
    @ObservationIgnored private let rateLimit: RateLimitGate
    @ObservationIgnored private let features: FeatureAvailability
    @ObservationIgnored private let requestLog: RequestLog

    public init(rateLimit: RateLimitGate, features: FeatureAvailability, requestLog: RequestLog) {
        self.rateLimit = rateLimit
        self.features = features
        self.requestLog = requestLog
    }

    public func setServerVersion(_ version: String) {
        serverVersion = version
    }

    public func setStreaming(_ state: StreamingState, for channel: Channel) {
        streaming[channel] = state
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
