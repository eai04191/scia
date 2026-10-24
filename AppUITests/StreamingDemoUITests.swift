import XCTest

/// デモの台本「流れても、動かない」。docs/promo-video.mdの流れのとおりに、操作とイベントを送る。
/// 録画は`make promo`で撮る。素材にするのは、始めと終わりに画面に一瞬出す目印（`mark`）の間。
final class StreamingDemoUITests: XCTestCase {
    @MainActor
    func testStreamingDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-scenario", "streaming"]
        app.launch()
        XCTAssertTrue(app.buttons["通知"].waitForExistence(timeout: 10))

        // ビューアは、起動して最初に開くときだけ準備で止まるので、撮る前に一度開いて4枚とも送り、閉じておく
        let photo = app.buttons["画像、夕焼けの空と丘"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        try openViewer()
        pause(1)
        for _ in 0..<3 {
            app.swipeLeft()
            pause(0.5)
        }
        app.swipeDown(velocity: .fast)
        pause(2)
        // 台本で下へ読み進めるときに出てくる行を、撮る前に一度出しておく。初めて出る行は、画像を読んで並べる分だけ、ドラッグの途中でコマが落ちる
        let screen = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        screen.press(forDuration: 0.05, thenDragTo: screen.withOffset(CGVector(dx: 0, dy: -500)), withVelocity: .fast, thenHoldForDuration: 0.5)
        pause(1)
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        upper.press(forDuration: 0.05, thenDragTo: upper.withOffset(CGVector(dx: 0, dy: 600)), withVelocity: .fast, thenHoldForDuration: 0)
        pause(2)

        let recordsInApp = try startRecording(app)
        pause(2)

        // 一番上にいると、新着が上から流れ込む
        try emit("arrivals-top")
        pause(3)

        // 下へ読み進め、4枚の写真の投稿で止まる
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        // 人が読み進めるときのように、軽くスワイプして指を離し、慣性で流して止める。
        // 長くゆっくりスワイプすると、指を離す直前に一瞬止まり、慣性が始まる前に4コマほど止まって見えたので、短く速くスワイプする
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -55)), withVelocity: XCUIGestureVelocity(700), thenHoldForDuration: 0)
        pause(2)

        // 読んでいる間に新着が来ても、読んでいる投稿は動かず、件数だけが出る
        let photoFrame = photo.frame
        try emit("arrivals-reading")
        pause(3)
        XCTAssertEqual(photo.frame.minY, photoFrame.minY, accuracy: 0.5, "新着で読んでいる投稿が動いた")

        // 写真を開いて次の写真へ。開いている間にも新着が来る
        try openViewer()
        pause(1.5)
        app.swipeLeft()
        try emit("arrivals-viewer")
        pause(2)

        // 下へスワイプして閉じると、元の位置に戻る
        app.swipeDown(velocity: .fast)
        pause(2)
        XCTAssertEqual(photo.frame.minY, photoFrame.minY, accuracy: 0.5, "ビューアを閉じたあと、読んでいた投稿の位置が変わった")

        // 新着の件数を押すと、一番上へ戻って新着が読める
        let arrivals = app.buttons.matching(NSPredicate(format: "label ENDSWITH '件の新着'")).firstMatch
        XCTAssertTrue(arrivals.exists)
        arrivals.tap()
        pause(3)

        // 通知が届き、通知のタブで読む
        try emit("favourite")
        pause(2)
        app.buttons["通知"].tap()
        pause(3)

        if recordsInApp {
            try emit("record-stop")
            // 書き出し終える前に取り出すと、ファイルがないか、途中までのものになる
            XCTAssertEqual(waitForRecorder(app, in: ["written", "failed"], timeout: 60), "written", "録画を書き出せなかった")
        } else {
            try markRecording()
        }
    }

    /// 録画を始める。
    /// シミュレーターでは`simctl io recordVideo`で撮っているので、素材の始めの目印を画面に出させる。シミュレーターでもアプリの中の録画（ReplayKit）は動くが、
    /// 二重に録画して描画を重くしないよう始めない。
    /// 実機ではアプリがReplayKitで撮り始め、初回だけ出る収録の許可を押す。録画そのものが台本の区間なので、目印は出さない。
    /// - Returns: アプリがReplayKitで撮っているか。撮り始められなかったら、台本を失敗させる。
    @MainActor
    private func startRecording(_ app: XCUIApplication) throws -> Bool {
        #if targetEnvironment(simulator)
        try markRecording()
        return false
        #else
        try emit("record-start")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
            print("PROMO-ALERT \(alert.label) \(labels)")
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS '収録' OR label CONTAINS 'Record'")).firstMatch
            XCTAssertTrue(allow.exists, "収録を許可するボタンがない: \(labels)")
            allow.tap()
        }
        let state = waitForRecorder(app, in: ["recording", "failed"], timeout: 10)
        XCTAssertEqual(state, "recording", "録画を始められなかった")
        return true
        #endif
    }

    /// 素材の始めと終わりの目印を、画面に一瞬出させる（`ScenarioMarker`）。目印が消えきるまで待つ。
    /// シミュレーターの録画から素材を切り出すために使う。
    @MainActor
    private func markRecording() throws {
        try emit("mark")
        pause(0.8)
    }

    /// 撮影モードのアプリが、ウインドウのaccessibilityIdentifierに`scenario-recorder:<状態>`の形で出す録画の状態を読み、
    /// `states`のどれかになるまで待つ。なったときの状態を返し、ならなければnilを返す。
    @MainActor
    private func waitForRecorder(_ app: XCUIApplication, in states: [String], timeout: TimeInterval) -> String? {
        let identifiers = states.map { "scenario-recorder:\($0)" }
        let window = app.windows.matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
        guard window.waitForExistence(timeout: timeout) else {
            let current = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'scenario-recorder:'")).firstMatch
            XCTFail("録画が\(states)のどれにもならない。今は\(current.exists ? current.identifier : "状態なし")")
            return nil
        }
        return String(window.identifier.dropFirst("scenario-recorder:".count))
    }

    /// 台本のイベントを、撮影モードのアプリに送る。
    @MainActor
    private func emit(_ event: String) throws {
        try signal("scenario/\(event)")
    }

    /// 画面のいちばん上に見えている写真付きの投稿の、1枚目の写真をビューアで開く。サムネイルをタップしたのと同じ経路で開く。
    /// XCUITestでタップすると、タップのあとにXCUITestが画面の要素を読む間、メインスレッドで動かしている開く動きが飛ぶため、アプリに合図して開かせる。
    @MainActor
    private func openViewer() throws {
        try signal("viewer?index=0")
    }

    /// 撮影モードのアプリに、同じ端末の中のプロセス間の通知（Darwin通知）で合図する（アプリ側は`ScenarioSignals`）。
    /// URLで合図すると、アプリが一度切り替わり、ステータスバーに「◀ Scia」が出て素材に写るため。
    private func signal(_ path: String) throws {
        let name = CFNotificationName(("net.mizle.scia.scenario." + path) as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
