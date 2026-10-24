public import Foundation
import os

/// なくても使える機能。サーバーによっては実装されていないことがある。
public enum OptionalFeature: String, Sendable, CaseIterable {
    /// 既読位置の読み込みと保存。https://docs.joinmastodon.org/methods/markers/
    case markers
    /// アカウントの設定（投稿の公開範囲の既定値、注意書きを開いておくか）。https://docs.joinmastodon.org/methods/preferences/
    case preferences
    /// v2の`instance`。投稿欄の上限とストリーミングの接続先に使う。https://docs.joinmastodon.org/methods/instance/#v2
    case instanceV2
    /// 複数の投稿をまとめて読む。Mastodon 4.3から。カードが付く前に受け取った投稿のカードを取り直すのに使う。
    /// https://docs.joinmastodon.org/methods/statuses/#index
    case multipleStatuses
    /// 複数のアカウントをまとめて読む。Mastodon 4.3から。メニューに、メンションされたユーザーのアイコンを出すのに使う。
    /// https://docs.joinmastodon.org/methods/accounts/#index
    case multipleAccounts
}

/// 使えないと分かった機能を、そのセッションの間だけ止める。セッションの中で共有する。
///
/// サーバーが更新されて使えるようになることがあるため、サーバーごとには覚えず、次のセッション（次の起動）でもう一度試す。
/// 止めたら、以後は送らずに`FeatureUnavailable`で失敗させ、使えないサーバーに同じリクエストを送り続けない。
public actor FeatureAvailability {
    public struct Disabled: Sendable, Equatable {
        public let feature: OptionalFeature
        /// 使えないと判断した応答のステータスコード。
        public let statusCode: Int
        public let date: Date
    }

    /// 止めた機能。止めた順。
    public private(set) var disabled: [Disabled] = []
    private let logger = SciaLog.logger(category: "network")
    private let now: @Sendable () -> Date

    /// - Parameter now: 止めた日時として残す今の日付。
    public init(now: @escaping @Sendable () -> Date = SystemTime.now) {
        self.now = now
    }

    /// 機能がないことを表すステータスコード。404は、IDを含まないパスでは機能そのものがないことを表す。
    static func indicatesUnsupported(statusCode: Int) -> Bool {
        [404, 405, 410, 501].contains(statusCode)
    }

    func check(_ feature: OptionalFeature) throws(FeatureUnavailable) {
        guard disabled.contains(where: { $0.feature == feature }) else { return }
        throw FeatureUnavailable(feature: feature)
    }

    func disable(_ feature: OptionalFeature, statusCode: Int) {
        guard !disabled.contains(where: { $0.feature == feature }) else { return }
        disabled.append(Disabled(feature: feature, statusCode: statusCode, date: now()))
        logger.info("feature disabled for session feature=\(feature.rawValue, privacy: .public) status=\(statusCode, privacy: .public)")
    }
}

/// このセッションでは使えないと分かった機能を、使おうとした。
public struct FeatureUnavailable: Error, Equatable, LocalizedError {
    public let feature: OptionalFeature

    public var errorDescription: String? { "このサーバーでは使えない機能です。" }
}
