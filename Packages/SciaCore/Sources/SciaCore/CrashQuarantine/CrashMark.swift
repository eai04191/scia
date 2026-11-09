public import Foundation
internal import CCrashMark

/// メインスレッドで処理している項目を、クラッシュしても残る形で記録する。決まりはdocs/crash-quarantine.mdにある。
public enum CrashMark {
    /// 前の起動がクラッシュしたときに処理していた項目。
    public struct Record: Equatable, Sendable {
        public let accountID: String
        public let itemID: String

        public init(accountID: String, itemID: String) {
            self.accountID = accountID
            self.itemID = itemID
        }
    }

    /// 前の起動の記録を読み、ファイルから消す。クラッシュしていなければnil。アカウントが記録されていないときもnil。
    public static func takeRecord(fileAt url: URL) -> Record? {
        var record = ccm_record()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { ccm_take_record($0, &record) } ?? false }) else { return nil }
        let itemID = withUnsafeBytes(of: record.item) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let accountID = withUnsafeBytes(of: record.account) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard !accountID.isEmpty else { return nil }
        return Record(accountID: accountID, itemID: itemID)
    }

    /// 記録を始める。入れられなければfalse。
    @MainActor public static func install(fileAt url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { $0.map { ccm_install($0) } ?? false }
    }

    @MainActor public static func setAccount(_ accountID: String) {
        var accountID = accountID
        accountID.withUTF8 { $0.withMemoryRebound(to: CChar.self) { ccm_set_account($0.baseAddress, $0.count) } }
    }

    @MainActor public static func setItem(_ itemID: String) {
        var itemID = itemID
        itemID.withUTF8 { $0.withMemoryRebound(to: CChar.self) { ccm_set_item($0.baseAddress, $0.count) } }
    }

    @MainActor public static func clearItem() {
        ccm_clear_item()
    }
}
