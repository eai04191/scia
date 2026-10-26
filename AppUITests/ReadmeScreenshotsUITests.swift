import XCTest

/// READMEのスクリーンショットのシナリオ（アプリ側は`ReadmeScreenshotsScenario`）。docs/promo-video.mdの「READMEのスクリーンショット」の3枚を撮る。
/// 撮った画像は結果のバンドルに添付として残し、`make readme-screenshots`が取り出してdocs/imagesに書き出す。添付の名前が書き出すファイルの名前になる。
final class ReadmeScreenshotsUITests: XCTestCase {
    @MainActor
    func testReadmeScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-scenario", "readme"]
        app.launch()
        XCTAssertTrue(app.buttons["通知"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["画像、夕焼けの空と丘"].waitForExistence(timeout: 5))

        // 少し読み進めたところに新着が届き、読んでいる位置は動かずに新着のボタンだけが出る
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -260)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.5)
        signal("arrivals-reading")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "5", "件の新着")).firstMatch.waitForExistence(timeout: 5), "新着のボタンが出ない")
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["通知"].value as? String == "2項目" }, "通知のタブにバッジが出ない: \(String(describing: app.buttons["通知"].value))")
        pause(1)
        capture("screenshot-timeline")

        // 写真付きの下書きを書き、送り終えるのを待って、末尾の`#`でハッシュタグの補完を出す
        signal("draft")
        let uploading = NSPredicate(format: "label == '画像' AND (value CONTAINS '中' OR value CONTAINS 'できませんでした')")
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons.matching(NSPredicate(format: "label == '画像'")).count == 3 && app.buttons.matching(uploading).count == 0 }, "下書きの写真を送り終えない")
        signal("draft-hashtag")
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'ハッシュタグ 写真'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "ハッシュタグの補完が出ない")
        pause(1)
        capture("screenshot-compose")

        // 下書きをカプセルに残して切り替えタブのリストを開き、お気に入りの通知をステータスバーに出す
        signal("draft-close")
        pause(1.5)
        app.buttons["写真"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["写真"].isSelected }, "リストが開かない")
        pause(1)
        signal("favourite")
        let ticker = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'あかりがお気に入りに登録しました'")).firstMatch
        XCTAssertTrue(ticker.waitForExistence(timeout: 5), "ステータスバーの通知が出ない")
        // 出てくる動きが終わるのを待つ
        pause(0.8)
        capture("screenshot-ticker")
    }

    /// `condition`が成り立つまで待つ。成り立てばtrue、`timeout`秒たっても成り立たなければfalseを返す。
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.2)
        }
        return condition()
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 撮影モードのアプリに、シナリオのイベントか操作をDarwin通知で送る（アプリ側は`ScenarioSignals`）。
    private func signal(_ event: String) {
        let name = CFNotificationName(("net.mizle.scia.scenario.scenario/" + event) as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
