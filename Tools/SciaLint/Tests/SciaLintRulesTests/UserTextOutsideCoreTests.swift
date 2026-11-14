@testable import SciaLintRules
import Testing

@Suite struct UserTextOutsideCoreTests {
    private func violations(_ source: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: source, path: path, rules: [.userTextOutsideCore]).count
    }

    @Test(arguments: [
        #"Button("すべてデフォルトに戻す") {}"#,
        #"let title = "\(handle)でブーストしました""#,
        #"button.accessibilityLabel = "閉じる""#,
        #"Text(verbatim: "カタカナ")"#,
        #"let label = "漢字""#,
        // ほかの呼び出しに包んで渡したものは、使う人に見えうるので見る
        #"logger.info(describe(Text("読み込み中")))"#,
    ])
    func flagsJapaneseText(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test(arguments: [
        #"Text(PostTexts.readMore)"#,
        #"let id = "status.toggled""#,
        #"let symbol = "arrow.2.squarepath""#,
        // 使う人に見えない文字列は見ない
        #"preconditionFailure("消せない項目を消そうとした")"#,
        #"logger.error("サーバーの版を読めない")"#,
        // デバッグ版だけに入るものは見ない
        "#if DEBUG\nlet title = \"ダミーの投稿\"\n#endif",
        // コメントは見ない
        "// 読み込み中\nlet x = 1",
    ])
    func ignoresOtherStrings(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test(arguments: ["App/Sources/Debug/Catalog/Foo.swift", "App/Sources/DiscomfortReport/Foo.swift", "App/Sources/Settings/AppInfo.generated.swift", "Packages/SciaCore/Sources/SciaCore/Foo.swift"])
    func ignoresFilesOutsideAppUI(_ path: String) {
        #expect(violations(#"let title = "読み込み中""#, path: path) == 0)
    }

    /// `#if DEBUG`のほかの枝は、Releaseにも入るので見る
    @Test func flagsReleaseBranch() {
        #expect(violations("#if DEBUG\nlet a = 1\n#else\nlet title = \"読み込み中\"\n#endif") == 1)
    }
}
