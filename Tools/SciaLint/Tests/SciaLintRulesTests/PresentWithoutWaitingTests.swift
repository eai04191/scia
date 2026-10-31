@testable import SciaLintRules
import Testing

@Suite struct PresentWithoutWaitingTests {
    private func violations(_ statement: String, path: String = "AppTests/FooTests.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.presentWithoutWaiting]).count
    }

    @Test(arguments: [
        "root.present(sheet, animated: false)",
        "present(sheet, animated: true, completion: nil)",
        // 引数を複数行に分けても見つける
        """
        root.present(
            sheet,
            animated: false
        )
        """,
    ])
    func flagsPresentingWithoutWaiting(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "try await root.presentForTesting(sheet)",
        "func present(_ viewController: UIViewController, animated: Bool) {}",
        "root.dismiss(animated: false)",
        "coordinator.present(sheet)",
    ])
    func allowsWaitingOrOtherCalls(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test func checksOnlyAppTests() {
        #expect(violations("root.present(sheet, animated: false)", path: "App/Sources/Foo.swift") == 0)
    }
}
