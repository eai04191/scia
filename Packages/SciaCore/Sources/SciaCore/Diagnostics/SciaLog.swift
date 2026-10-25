public import Foundation
public import os

/// アプリのログ。違和感レポートはこのsubsystemのログを集める。
/// 何を`privacy: .public`で出してよいかは、docs/logging.mdに決めてある。
public enum SciaLog {
    public static let subsystem = "net.mizle.scia"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// ログに書く失敗の説明。応答の本文やサーバーが返した文言、読めなかった値は個人情報を含みうるため含めない。
    /// `localizedDescription`は、APIの失敗では応答の本文を、ファイルの失敗ではファイルのパスを含むため、ログには使わない。
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MastodonAPIError: "HTTP \(error.statusCode)"
        case let error as URLError: "URLError \(error.code.rawValue)"
        case let error as DecodingError: "decoding \(DecodingLog.describe(error))"
        case let error as CocoaError: "CocoaError \(error.code.rawValue)"
        default: describeOther(error)
        }
    }

    /// OSのフレームワークが返す`NSError`は、型の名前だけでは何の失敗か分からないため、領域とコードを残す。
    /// アプリが定義した失敗は、型の名前で分かる。
    private static func describeOther(_ error: any Error) -> String {
        guard type(of: error) is NSError.Type else { return String(describing: type(of: error)) }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// ログに残すURLのホスト。パスとクエリは、ユーザーやID、ファイルの名前を含むため残さない。
    public static func host(of url: URL?) -> String {
        url?.host() ?? "nil"
    }
}
