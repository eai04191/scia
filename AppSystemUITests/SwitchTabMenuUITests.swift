import XCTest

/// 切り替えタブを長押ししたメニューが、投稿欄の下端より上に出るか。
/// メニューの位置は`ContextMenuPositioner`が、UIKitの公開されていない作りを頼りにメニューを見つけて直している。iOSの更新で作りが変わると、
/// メニューが見つからず、丸いボタンに重なる位置のまま出る。ユニットテストではUIKitに本物のメニューを出させられないので、実際に長押しして確かめる。
/// ダミーのセッションで、切り替えタブにローカルと連合を入れた並びにして始める。
final class SwitchTabMenuUITests: XCTestCase {
    @MainActor
    func testMenuSitsAboveComposer() throws {
        // 切り替えタブを切り離して長押しのメニューを出すのは、iOS 27以降だけ。
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("切り替えタブの長押しのメニューは、iOS 27以降にしかない")
        }
        let app = XCUIApplication()
        // 設定は起動の引数でも渡せる。ダミーのセッションのアカウントの並びを、ホームと通知をタブに、ローカルと連合を切り替えタブにする。
        // 端末に残った、切り替えタブで最後に開いた項目も、ローカルに決める。
        app.launchArguments = [
            "-account.@me@dummy.invalid/tabLayout", "(item:home, item:notifications, more, item:local, item:federated)",
            "-account.@me@dummy.invalid/switchTabItem", "local",
        ]
        app.launch()
        try app.open(XCTUnwrap(URL(string: "scia-debug://dummy-session")))
        // 端末で初めてURLを送ったときは、システムが「“Scia”で開きますか？」と聞く。
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["開く"]
        if open.waitForExistence(timeout: 3) {
            open.tap()
        }

        let switchTab = app.tabBars.buttons["ローカル"]
        XCTAssertTrue(switchTab.waitForExistence(timeout: 10), "切り替えタブが出ていない")
        switchTab.press(forDuration: 1)

        // 2項目のメニューで、下の項目は連合。タブバーには連合のタブがないので、メニューの項目だけに当たる。
        let lastItem = app.buttons["連合"]
        XCTAssertTrue(lastItem.waitForExistence(timeout: 5), "長押しでメニューが出ない")
        let composer = app.buttons["投稿欄"]
        XCTAssertTrue(composer.exists, "投稿欄が出ていない")
        XCTAssertLessThanOrEqual(lastItem.frame.maxY, composer.frame.maxY, "メニューが投稿欄より下に出ている。iOSの更新でContextMenuPositionerがメニューを見つけられなくなった")
    }
}
