import Testing
@testable import SciaLintRules

@Suite struct BackgroundNotificationInTestTests {
    private func violations(_ statement: String, path: String = "AppTests/FooTests.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.backgroundNotificationInTest]).count
    }

    @Test(arguments: [
        "NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)",
        "center.post(name: .didEnterBackgroundNotification, object: nil)",
    ])
    func flagsPostingBackgroundNotification(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        "whileInBackground { #expect(store.image(for: url) != nil) }",
        "NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)",
    ])
    func allowsOtherCode(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test func appliesOnlyToAppTests() {
        let statement = "NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)"
        #expect(violations(statement, path: "App/Sources/Foo.swift") == 0)
    }
}
