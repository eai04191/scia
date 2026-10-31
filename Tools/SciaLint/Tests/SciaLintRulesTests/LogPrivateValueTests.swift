@testable import SciaLintRules
import Testing

@Suite struct LogPrivateValueTests {
    private func violations(_ statement: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: statement, path: path, rules: [.logPrivateValue]).count
    }

    @Test(arguments: [
        #"logger.error("failed: \(error)")"#,
        #"logger.error("failed: \(error, privacy: .public)")"#,
        #"logger.error("failed: \(self.failure)")"#,
        #"logger.info("open \(url)")"#,
        #"logger.info("open \(request.url?.path ?? "")")"#,
        #"logger.info("open \(url.absoluteString, privacy: .public)")"#,
        #"logger.info("user \(account.acct)")"#,
        #"logger.info("text \(status.content)")"#,
        #"logger.info("text \(draft.text.uppercased())")"#,
        #"logger.notice("failed \(String(describing: error))")"#,
        #"logger.error("failed \(String(describing: error as NSError), privacy: .public)")"#,
        #"logger.error("failed \(String(describing: self.failure.code), privacy: .public)")"#,
        #"logger.error("failed \(Swift.String(describing: error), privacy: .public)")"#,
        #"logger.error("failed \(error.localizedDescription, privacy: .auto)")"#,
        // 括弧が深くても、補間の中を最後まで見る
        #"logger.info("x \(f(g(h(account.displayName))))")"#,
        // 複数行の文字列の中も見る
        #"""
        logger.info(
            """
            user
            \(account.username)
            """
        )
        """#,
    ])
    func flagsPublicValues(_ statement: String) {
        #expect(violations(statement) == 1)
    }

    @Test(arguments: [
        #"logger.error("failed: \(error, privacy: .private)")"#,
        #"logger.error("failed: \(error, privacy: .private(mask: .hash))")"#,
        #"logger.error("failed: \(error, privacy: .sensitive)")"#,
        #"logger.error("failed: \(SciaLog.describe(error), privacy: .public)")"#,
        #"logger.info("open \(SciaLog.host(of: url), privacy: .public)")"#,
        #"logger.info("open \(url.host ?? "")")"#,
        #"logger.info("count \(status.content.count)")"#,
        #"logger.info("empty \(draft.text?.isEmpty ?? true)")"#,
        #"logger.info("tab \(tab.rawValue, privacy: .public)")"#,
        #"logger.info("errors \(errorCount)")"#,
        // ログ以外の呼び出しの文字列は見ない
        #"print("failed: \(error)")"#,
        // 最初の引数でない文字列は見ない
        #"logger.log(level: .info, "x")"#,
    ])
    func allowsHiddenOrHarmlessValues(_ statement: String) {
        #expect(violations(statement) == 0)
    }

    @Test(arguments: ["App/Sources/Debug/Foo.swift", "AppTests/Foo.swift", "Packages/SciaCore/Sources/SciaTesting/Foo.swift"])
    func skipsFilesOutsideTheRelease(_ path: String) {
        #expect(violations(#"logger.error("failed: \(error)")"#, path: path) == 0)
    }

    @Test(arguments: ["App/Sources/Foo.swift", "ShareExtension/Foo.swift", "Packages/SciaCore/Sources/SciaCore/Foo.swift"])
    func checksReleaseFiles(_ path: String) {
        #expect(violations(#"logger.error("failed: \(error)")"#, path: path) == 1)
    }
}
