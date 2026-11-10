@testable import SciaLintRules
import Testing

@Suite struct TuningItemNotInSectionsTests {
    private static let catalogPath = "Packages/SciaCore/Sources/SciaCore/Tuning/TuningItem.swift"

    private func violations(_ source: String, path: String = catalogPath) -> [Violation] {
        Linter.lint(source: source, path: path, rules: [.tuningItemNotInSections])
    }

    private func catalog(items: String, sections: String) -> String {
        """
        public enum TuningCatalog {
        \(items)
            public static let sections: [TuningSection] = [
                TuningSection(id: sectionID, title: "見た目", items: [
        \(sections)
                ]),
            ]
        }
        """
    }

    @Test func allowsItemsListedInSections() {
        let source = catalog(
            items: """
                public static let sectionID = "timeline"
                public static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
                public static let follows = ToggleTuning(id: "b", title: "追従", defaultValue: true)
                static let typed: NumberTuning = .init(id: "c", title: "型", range: 0...1, step: 0.05, defaultValue: 0.5)
            """,
            sections: ".number(strength), .toggle(TuningCatalog.follows), .number(Self.typed),"
        )
        #expect(violations(source).isEmpty)
    }

    @Test func flagsItemMissingFromSections() {
        let source = catalog(
            items: """
                public static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
                public static let follows = ToggleTuning(id: "b", title: "追従", defaultValue: true)
                static let typed: NumberTuning = .init(id: "c", title: "型", range: 0...1, step: 0.05, defaultValue: 0.5)
            """,
            sections: ".number(strength),"
        )
        #expect(violations(source).map(\.line) == [3, 4])
    }

    /// コメントや文字列に名前があっても、入れたことにならない
    @Test func ignoresNamesInCommentsAndStrings() {
        let source = catalog(
            items: """
                public static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
            """,
            sections: "// .number(strength),\n.toggle(ToggleTuning(id: \"strength\", title: \"strength\", defaultValue: true)),"
        )
        #expect(violations(source).count == 1)
    }

    /// ほかの場所で使っていても、`sections`になければ止める
    @Test func flagsItemUsedOnlyOutsideSections() {
        let source = catalog(
            items: """
                public static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
                static let all = [strength]
            """,
            sections: ""
        )
        #expect(violations(source).count == 1)
    }

    /// 別のファイルのextensionに定義した項目は、`sections`と突き合わせられないので止める
    @Test func flagsItemInExtensionWithoutSections() {
        let source = """
        extension TuningCatalog {
            static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
        }
        """
        #expect(violations(source, path: "App/Sources/Timeline/Tuning.swift").count == 1)
    }

    @Test func allowsItemInExtensionOfTheSameFile() {
        let source = catalog(items: "", sections: ".number(strength),") + """

        extension TuningCatalog {
            static let strength = NumberTuning(id: "a", title: "強さ", range: 0...1, step: 0.05, defaultValue: 0.5)
        }
        """
        #expect(violations(source).isEmpty)
    }

    @Test(arguments: [
        // ほかの型の中の項目は、テストなどが自分で`TuningStore`に渡す
        "enum Other { static let strength = NumberTuning(id: \"a\", title: \"強さ\", range: 0...1, step: 0.05, defaultValue: 0.5) }",
        // 項目でない値
        "enum TuningCatalog { static let sectionID = \"timeline\"\nstatic let count: Int = 3 }",
    ])
    func allowsOtherDeclarations(_ source: String) {
        #expect(violations(source).isEmpty)
    }

    @Test(arguments: [
        "Packages/SciaCore/Tests/SciaCoreTests/TuningStoreTests.swift",
        "AppTests/TuningTests.swift",
    ])
    func ignoresTests(_ path: String) {
        let source = "enum TuningCatalog { static let strength = NumberTuning(id: \"a\", title: \"強さ\", range: 0...1, step: 0.05, defaultValue: 0.5) }"
        #expect(violations(source, path: path).isEmpty)
    }
}
