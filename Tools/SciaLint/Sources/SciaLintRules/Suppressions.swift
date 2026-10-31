import SwiftSyntax

/// `// scialint:disable <規則>`から`// scialint:enable <規則>`までと、`// scialint:disable:next <規則>`の次の行、
/// `// scialint:disable:this <規則>`の行で、規則を外す。書き方はSwiftLintの除外のコメントに揃える。
/// SwiftLintのコメントに書くと、SwiftLintが知らない規則の名前として警告するため、前置きを分けている
struct Suppressions {
    private var regions: [String: [ClosedRange<Int>]] = [:]
    private(set) var errors: [Violation] = []

    init(tree: SourceFileSyntax, converter: SourceLocationConverter, knownRules: Set<String>) {
        var openRegions: [String: Int] = [:]
        func handle(_ piece: TriviaPiece, at position: AbsolutePosition) {
            guard case let .lineComment(text) = piece else { return }
            let words = text.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command = words.first, command.hasPrefix("scialint:") else { return }
            let line = converter.location(for: position).line
            let commands = ["scialint:disable", "scialint:enable", "scialint:disable:next", "scialint:disable:this"]
            guard commands.contains(command) else {
                errors.append(Violation(rule: "scialint", line: line, column: 1, message: "知らない指示: \(command)"))
                return
            }
            let rules = words.dropFirst()
            if rules.isEmpty {
                errors.append(Violation(rule: "scialint", line: line, column: 1, message: "外す規則の名前を書く"))
            }
            for rule in rules {
                guard knownRules.contains(rule) else {
                    errors.append(Violation(rule: "scialint", line: line, column: 1, message: "知らない規則の名前: \(rule)"))
                    continue
                }
                switch command {
                case "scialint:disable":
                    openRegions[rule] = openRegions[rule] ?? line
                case "scialint:enable":
                    if let start = openRegions.removeValue(forKey: rule) {
                        regions[rule, default: []].append(start...line)
                    }
                case "scialint:disable:next":
                    regions[rule, default: []].append((line + 1)...(line + 1))
                default:
                    regions[rule, default: []].append(line...line)
                }
            }
        }

        for token in tree.tokens(viewMode: .sourceAccurate) {
            var offset = token.position
            for piece in token.leadingTrivia {
                defer { offset += piece.sourceLength }
                handle(piece, at: offset)
            }
            offset = token.endPositionBeforeTrailingTrivia
            for piece in token.trailingTrivia {
                defer { offset += piece.sourceLength }
                handle(piece, at: offset)
            }
        }
        let lastLine = converter.location(for: tree.endPosition).line
        for (rule, start) in openRegions {
            regions[rule, default: []].append(start...lastLine)
        }
    }

    func isSuppressed(rule: String, line: Int) -> Bool {
        regions[rule, default: []].contains { $0.contains(line) }
    }
}
