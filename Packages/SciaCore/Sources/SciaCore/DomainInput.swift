import Foundation

/// 人が入れたサーバーのドメイン。URLやハンドルをそのまま貼っても、ドメインとして扱えるようにする。
public enum DomainInput {
    /// `https://`や末尾の`/`、`@alice@`のようなアカウントの部分を除き、ドメインとして比べられる形にする。
    public static func normalize(_ input: String) -> String {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = query.range(of: "://") {
            query = String(query[range.upperBound...])
        }
        if let slash = query.firstIndex(of: "/") {
            query = String(query[..<slash])
        }
        if let at = query.lastIndex(of: "@") {
            query = String(query[query.index(after: at)...])
        }
        return query
    }
}
