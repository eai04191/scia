public import Foundation

/// この端末でログアウトしたアカウントとして送ろうとした。送っていないので、届いたか分からない失敗とは分ける。
/// 端末から消したアカウントはログインし直しても戻さないので、401と違い、ログインし直すボタンの付かない失敗にする。
public struct RemovedAccount: LocalizedError, Sendable {
    public let handle: String

    public init(handle: String) {
        self.handle = handle
    }

    public var errorDescription: String? {
        AccountSwitchTexts.removedAccount(handle: handle)
    }
}
