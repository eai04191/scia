import Foundation
public import os

/// アプリのログ。違和感レポートはこのsubsystemのログを集める。
public enum SciaLog {
    public static let subsystem = "net.mizle.scia"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// ログに書く失敗の説明。応答の本文やサーバーが返した文言、読めなかった値は個人情報を含みうるため含めない。
    /// `localizedDescription`は、APIの失敗では応答の本文を含むため、ログには使わない。
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MastodonAPIError: "HTTP \(error.statusCode)"
        case let error as URLError: "URLError \(error.code.rawValue)"
        case let error as DecodingError: "decoding \(DecodingLog.describe(error))"
        default: String(describing: type(of: error))
        }
    }
}
