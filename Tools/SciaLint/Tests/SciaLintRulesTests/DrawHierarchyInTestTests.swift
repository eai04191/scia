import Testing
@testable import SciaLintRules

@Suite struct DrawHierarchyInTestTests {
    private func violations(_ statement: String, path: String = "AppTests/FooTests.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.drawHierarchyInTest]).count
    }

    @Test(arguments: [
        "window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)",
        "_ = view.drawHierarchy(in: rect, afterScreenUpdates: false)",
    ])
    func flagsDirectDrawHierarchy(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test func allowsDrawer() {
        #expect(violations("let image = drawer.image(of: window)") == 0)
    }

    @Test(arguments: ["App/Sources/Foo.swift", "AppTests/Support/HierarchyDrawer.swift"])
    func appliesOnlyToTestsOutsideDrawer(_ path: String) {
        #expect(violations("view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)", path: path) == 0)
    }
}
