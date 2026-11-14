public import Foundation

/// ハンドルの人が、サーバーで見つからなかった。
public struct ProfileNotFound: LocalizedError, Equatable {
    public let acct: String

    public init(acct: String) {
        self.acct = acct
    }

    public var errorDescription: String? { "@\(acct)が見つかりませんでした。" }
}
