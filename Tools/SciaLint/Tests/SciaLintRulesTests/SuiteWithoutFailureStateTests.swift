import Testing
@testable import SciaLintRules

@Suite struct SuiteWithoutFailureStateTests {
    private func violations(_ source: String, path: String = "AppTests/FooTests.swift") -> [Int] {
        Linter.lint(source: source, path: path, rules: [.suiteWithoutFailureState]).map(\.line)
    }

    @Test(arguments: [
        "struct FooTests {\n    @Test func a() {}\n    @Test func b() {}\n}",
        "@MainActor\n@Suite(.scratch, .serialized)\nfinal class FooTests {\n    @Test func a() {}\n}",
        "@Suite struct FooTests {\n    @Test(arguments: [1, 2]) func a(_ value: Int) {}\n}",
    ])
    func flagsSuiteOnce(_ source: String) {
        #expect(violations(source) == [1])
    }

    @Test(arguments: [
        "@Suite(.failureState) struct FooTests {\n    @Test func a() {}\n}",
        "@MainActor\n@Suite(.scratch, .serialized, .failureState)\nfinal class FooTests {\n    @Test func a() {}\n}",
        "struct Helper {\n    func make() {}\n}",
    ])
    func allowsSuiteWithTraitAndTypesWithoutTests(_ source: String) {
        #expect(violations(source).isEmpty)
    }

    @Test func nestedSuiteInheritsFromOuter() {
        #expect(violations("@Suite(.failureState) struct Outer {\n    struct Inner {\n        @Test func a() {}\n    }\n}").isEmpty)
        #expect(violations("struct Outer {\n    @Suite(.failureState) struct Inner {\n        @Test func a() {}\n    }\n}").isEmpty)
        #expect(violations("struct Outer {\n    struct Inner {\n        @Test func a() {}\n    }\n}") == [1])
    }

    @Test func skipsTestsInExtension() {
        #expect(violations("@Suite(.failureState) struct FooTests {\n    @Test func a() {}\n}\nextension FooTests {\n    @Test func b() {}\n}").isEmpty)
        #expect(violations("struct FooTests {\n    @Test func a() {}\n}\nextension FooTests {\n    @Test func b() {}\n}") == [1])
    }

    @Test func freeTestNeedsTraitOnItself() {
        #expect(violations("@Test func a() {}") == [1])
        #expect(violations("@Test(.failureState) func a() {}").isEmpty)
    }

    @Test func appliesOnlyToAppTests() {
        #expect(violations("struct FooTests {\n    @Test func a() {}\n}", path: "Packages/SciaCore/Tests/SciaCoreTests/FooTests.swift").isEmpty)
    }
}
