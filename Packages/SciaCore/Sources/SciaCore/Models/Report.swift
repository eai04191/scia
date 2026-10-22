/// 通報の理由の種類。
/// https://docs.joinmastodon.org/entities/Report/#category
public enum ReportCategory: String, CaseIterable, Sendable {
    /// 不要な、または繰り返しの内容。
    case spam
    /// サーバーのルールへの違反。違反したルールを選ぶ。
    case violation
    /// 違法な内容。
    case legal
    case other
}

/// サーバーのルール。
/// https://docs.joinmastodon.org/entities/Rule/
public struct InstanceRule: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// ルールの長い説明。Mastodon 4.3より前のサーバーは返さない。
    public let hint: String?

    public init(id: String, text: String, hint: String? = nil) {
        self.id = id
        self.text = text
        self.hint = hint
    }
}

/// サーバーに送る通報。
public struct ReportRequest: Equatable, Sendable {
    public var accountID: String
    public var statusIDs: [String]
    public var comment: String
    /// ほかのサーバーのアカウントなら、そのサーバーの管理者にも転送する。
    public var forward: Bool
    public var category: ReportCategory
    /// `violation`のときだけ送る。サーバーは、ほかの種類でルールを渡すと受け付けないため。
    public var ruleIDs: [String]

    public init(accountID: String, statusIDs: [String] = [], comment: String = "", forward: Bool = false, category: ReportCategory, ruleIDs: [String] = []) {
        self.accountID = accountID
        self.statusIDs = statusIDs
        self.comment = comment
        self.forward = forward
        self.category = category
        self.ruleIDs = ruleIDs
    }
}
