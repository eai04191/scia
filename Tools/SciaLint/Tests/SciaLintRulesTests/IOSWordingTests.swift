@testable import SciaLintRules
import Testing

@Suite struct IOSWordingTests {
    private func violations(_ source: String, path: String = "App/Sources/Foo.swift") -> Int {
        Linter.lint(source: source, path: path, rules: [.iosWording]).count
    }

    @Test(arguments: [
        #"Button("すべて既定に戻す") {}"#,
        #"let title = "下書きを捨てますか？""#,
        #"alert.addAction(UIAlertAction(title: "止める", style: .destructive))"#,
        #"let message = "端末の空き容量が足りません。""#,
        #"let message = "しばらく待ってからやり直してください。""#,
        #"Text("区切り線を足す")"#,
        #"Toggle("時刻を出す", isOn: $on)"#,
        #"Text("メニューに「カスタマイズ」を出します。")"#,
        #"Text("結果を見せる")"#,
        #"Button("\(name)を消す") {}"#,
        #"button.accessibilityHint = "押すと読み込み直します""#,
        // ログでない受け手の、ログと同じ名前の呼び出しは見る
        #"Banner.error("下書きを捨てる")"#,
        // ほかの呼び出しに包んで渡したものは、使う人に見えうるので見る
        #"preconditionFailure(message(title: "下書きを捨てる"))"#,
        #"logger.info(describe(Text("下書きを捨てる")))"#,
        // 補間で分かれても、文字列の部分で見つける
        #"let title = "\(handle)の下書きを捨てて\(action)""#,
    ])
    func flagsAvoidedWording(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test(arguments: [
        #"Button("すべてデフォルトに戻す") {}"#,
        #"Button("お気に入りを取り消す") {}"#,
        #"let title = "予約を取り消せませんでした""#,
        #"let title = "フォローのリクエストを取り消しました""#,
        #"Text("開く途中に末尾へ打ち足す")"#,
        #"let message = "ストレージの容量が不足しています。""#,
        #"Text("理由を補足してください")"#,
        #"Text("満足しました")"#,
        // 使う人に見えない文字列は見ない
        #"preconditionFailure("消せない項目を消そうとした")"#,
        #"precondition(range.contains(value), "\(id)の既定値が範囲外です")"#,
        #"logger.error("端末の状態を読めない")"#,
        #"Self.logger.info("下書きを捨てた")"#,
        #"SciaLog.logger(category: "compose").notice("下書きを捨てた")"#,
        // コメントは見ない
        "// 下書きを捨てる\nlet x = 1",
    ])
    func allowsOtherWording(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test(arguments: [
        "App/Sources/Debug/DebugMenu.swift",
        "App/Sources/DiscomfortReport/DiscomfortReportView.swift",
        "Packages/SciaCore/Sources/SciaCore/Tuning/TuningItem.swift",
        "AppTests/Foo.swift",
    ])
    func skipsDebugAndTests(_ path: String) {
        #expect(violations(#"Text("下書きを捨てる")"#, path: path) == 0)
    }

    @Test(arguments: [
        "App/Sources/Foo.swift",
        "ShareExtension/Foo.swift",
        "Packages/SciaCore/Sources/SciaCore/Foo.swift",
    ])
    func checksReleaseSources(_ path: String) {
        #expect(violations(#"Text("下書きを捨てる")"#, path: path) == 1)
    }
}
