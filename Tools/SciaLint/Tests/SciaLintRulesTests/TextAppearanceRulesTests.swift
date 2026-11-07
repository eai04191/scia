@testable import SciaLintRules
import Testing

@Suite struct FixedFontSizeTests {
    private func violations(_ statement: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.fixedFontSize]).count
    }

    @Test(arguments: [
        "label.font = .systemFont(ofSize: 14)",
        "label.font = UIFont.boldSystemFont(ofSize: 14)",
        "label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)",
        "Text(title).font(.system(size: 14))",
        "Text(title).font(Font.system(size: 14, weight: .bold))",
        // 別の文で大きさを変えても、作った文字は止める
        "let font = UIFont.systemFont(ofSize: 14); label.font = metrics.scaledFont(for: other)",
        // 引数を複数行に分けても見つける
        """
        label.font = .systemFont(
            ofSize: 14,
            weight: .bold
        )
        """,
    ])
    func flagsFixedSizes(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 14))",
        "label.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: font.pointSize, weight: weight))",
        // 引数を複数行に分けても、UIFontMetricsで大きさを変えていれば止めない
        """
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        )
        """,
        "label.font = .preferredFont(forTextStyle: .body)",
        "Text(title).font(.system(.body))",
        "label.font = .monospacedDigitFont(forTextStyle: .body)",
    ])
    func allowsScaledFonts(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test(arguments: ["App/Sources/Debug/Foo.swift", "AppTests/Foo.swift"])
    func skipsDebugAndTests(_ path: String) {
        #expect(violations("label.font = .systemFont(ofSize: 14)", path: path) == 0)
    }

    /// アプリから分けたラベルのパッケージも、アプリの文字として描くので同じく止める。
    @Test func appliesToLabelPackage() {
        #expect(violations("label.font = .systemFont(ofSize: 14)", path: "Packages/TextKit2Label/Sources/TextKit2Label/Foo.swift") == 1)
    }
}

@Suite struct DimmedWhiteTextTests {
    private func violations(_ statement: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.dimmedWhiteText]).count
    }

    @Test(arguments: [
        "label.textColor = .white.withAlphaComponent(0.6)",
        "label.textColor = UIColor.white.withAlphaComponent(0.6)",
        "field.placeholderTextColor = .white.withAlphaComponent(0.6)",
        "Text(title).foregroundStyle(.white.opacity(0.7))",
        "Text(title).foregroundColor(Color.white.opacity(0.7))",
        "Renderer(font: font, textColor: .white.withAlphaComponent(0.5))",
        "let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.white.withAlphaComponent(0.5)]",
        "label.textColor = isPlaceholder ? .white.withAlphaComponent(0.6) : .white",
        "text.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.6), range: range)",
        """
        text.addAttribute(
            NSAttributedString.Key.foregroundColor,
            value: UIColor.white
                .withAlphaComponent(0.6),
            range: range
        )
        """,
        // 白い文字にしたビューを透かす
        "Text(title).foregroundStyle(.white).opacity(0.6)",
        "Text(title).foregroundColor(.white).padding().opacity(0.6)",
        // 引数を複数行に分けても見つける
        """
        Text(title)
            .foregroundStyle(
                .white
                    .opacity(0.7)
            )
        """,
    ])
    func flagsTranslucentWhiteText(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "label.textColor = .dimmedWhiteText(alpha: 0.6)",
        "label.textColor = .white",
        "view.backgroundColor = .white.withAlphaComponent(0.6)",
        "Rectangle().fill(.white.opacity(0.3))",
        "text.addAttribute(.backgroundColor, value: UIColor.white.withAlphaComponent(0.6), range: range)",
        "Text(title).foregroundStyle(.black).opacity(0.6)",
        "label.textColor = .black.withAlphaComponent(0.6)",
        // 閉包の中の文の色は、閉包を渡した呼び出しの引数として見ない
        "Text(title).foregroundStyle(.primary).background { Color.white.opacity(0.3) }",
    ])
    func allowsOtherColors(_ statement: String) {
        #expect(violations(statement) == 0)
    }
}
