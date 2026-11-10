import SwiftParser
import SwiftSyntax

/// 構文木で調べる規則。どのファイルを調べるかと、違反の位置を見つける処理を持つ。
public struct Rule: Sendable {
    public let id: String
    public let message: String
    /// リポジトリのルートからの相対パスを受け取り、調べるファイルならtrueを返す
    public let appliesTo: @Sendable (String) -> Bool
    /// 違反した構文の位置を返す
    let find: @Sendable (SourceFileSyntax) -> [AbsolutePosition]
}

public struct Violation: Equatable, Sendable {
    public let rule: String
    public let line: Int
    public let column: Int
    public let message: String
}

public enum Linter {
    public static let rules: [Rule] = [
        .logPrivateValue,
        .sessionTaskOutsideScope,
        .taskWithoutRequestPurpose,
        .presentWithoutWaiting,
        .backgroundNotificationInTest,
        .fixedFontSize,
        .dimmedWhiteText,
        .timelineStoreWithoutTester,
        .iosWording,
        .exactCountWait,
        .advanceAfterSleeperCount,
        .synthesizedServerValueDecoding,
        .tuningItemNotInSections,
    ]

    /// `path`（リポジトリのルートからの相対パス）の`source`を、当てはまる規則で調べる。
    /// 除外のコメントに知らない規則の名前があれば、書き間違いで規則が外れたままにならないよう、それも違反として返す
    public static func lint(source: String, path: String, rules: [Rule] = rules) -> [Violation] {
        let applicable = rules.filter { $0.appliesTo(path) }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let suppressions = Suppressions(tree: tree, converter: converter, knownRules: Set(Linter.rules.map(\.id)))
        var violations = suppressions.errors
        for rule in applicable {
            for position in rule.find(tree) {
                let location = converter.location(for: position)
                guard !suppressions.isSuppressed(rule: rule.id, line: location.line) else { continue }
                violations.append(Violation(rule: rule.id, line: location.line, column: location.column, message: rule.message))
            }
        }
        return violations.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }
}
