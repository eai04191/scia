/// ユーザーのメニューの見出し。どこから出すメニューでも同じ人が同じ見出しに見えるよう、この形で揃える。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
public struct UserHeading: Equatable, Sendable {
    /// `@`を付けた名前。サーバー名は含めない。
    public let title: String
    /// ほかのサーバーのユーザーなら、`@`を付けないサーバー名。自分のサーバーのユーザーならnil。
    public let subtitle: String?

    /// - Parameter acct: ローカルのユーザーならusername、リモートならusername@domain。
    public init(acct: String) {
        let parts = acct.split(separator: "@", maxSplits: 1)
        title = "@\(parts.first ?? Substring(acct))"
        subtitle = parts.count == 2 ? String(parts[1]) : nil
    }
}
