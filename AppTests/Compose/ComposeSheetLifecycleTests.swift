import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の下に出すシートが閉じたことを、UIKitの開閉の知らせが来ても来なくても、一度だけ知らせるか確かめる。
@MainActor
struct ComposeSheetLifecycleTests {
    private final class Recorder {
        var willClose = 0
        var didClose = 0
        var didAppear = 0
    }

    private func makeHost() throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    private func makeLifecycle() -> (ComposeSheetLifecycle, UIViewController, Recorder) {
        let controller = UIViewController()
        let lifecycle = ComposeSheetLifecycle(controller: controller, name: "test sheet")
        let recorder = Recorder()
        lifecycle.onWillClose = { recorder.willClose += 1 }
        lifecycle.onDidClose = { recorder.didClose += 1 }
        lifecycle.onDidAppear = { recorder.didAppear += 1 }
        return (lifecycle, controller, recorder)
    }

    private func presentAndWait(_ lifecycle: ComposeSheetLifecycle, _ controller: UIViewController, from host: UIViewController, recorder: Recorder) async throws {
        lifecycle.present(from: host)
        try await waitUntil { recorder.didAppear > 0 }
        #expect(controller.presentingViewController === host)
    }

    /// 閉じた知らせ（`presentationControllerDidDismiss`）が来ないままシートが消えても、キーボードを戻す知らせと閉じ終わりを1回ずつ出す。
    /// 出さないと、投稿欄はシートを出しているつもりのままになり、写真のボタンも絵文字のボタンも何もしなくなる。
    @Test func reportsCloseWhenSheetDisappearsWithoutDismissCallback() async throws {
        let (window, host) = try makeHost()
        defer { window.isHidden = true }
        let (lifecycle, controller, recorder) = makeLifecycle()
        try await presentAndWait(lifecycle, controller, from: host, recorder: recorder)

        // プログラムから閉じると、UIKitは閉じた知らせを出さない。知らせなしに消える場合を、これで作る。
        try await controller.dismissForTesting()

        try await waitUntil { recorder.didClose > 0 }
        #expect(recorder.willClose == 1)
        #expect(recorder.didClose == 1)
        #expect(lifecycle.isClosing)
        #expect(lifecycle.disappearedWithoutDismissCallback)
        #expect(!lifecycle.isPresentedOrPending)
    }

    /// 下へスワイプして閉じたときのように閉じた知らせが来ても、閉じ終わりは1回だけ出す。
    @Test func reportsCloseOnceWhenDismissCallbackAlsoArrives() async throws {
        let (window, host) = try makeHost()
        defer { window.isHidden = true }
        let (lifecycle, controller, recorder) = makeLifecycle()
        try await presentAndWait(lifecycle, controller, from: host, recorder: recorder)

        try await controller.dismissForTesting()
        lifecycle.presentationControllerDidDismiss()

        try await waitUntil { recorder.didClose > 0 }
        #expect(recorder.didClose == 1)
    }

    /// ボタンで閉じたときも、閉じ終わりは1回だけ出す。
    @Test func reportsCloseOnceWhenClosedFromButton() async throws {
        let (window, host) = try makeHost()
        defer { window.isHidden = true }
        let (lifecycle, controller, recorder) = makeLifecycle()
        try await presentAndWait(lifecycle, controller, from: host, recorder: recorder)

        lifecycle.close(notifiesWillClose: true)

        try await waitUntil { recorder.didClose > 0 && host.presentedViewController == nil }
        #expect(recorder.willClose == 1)
        #expect(recorder.didClose == 1)
    }

    /// 前のシートが閉じる途中に出したシートは、UIKitが閉じ終わるまで出すのを遅らせる。その間に閉じるよう頼まれたら、出し終えたところで閉じる。
    /// 何もしないと、出したあとに閉じる手段がなくなる。
    @Test func closesAfterShownWhenClosedBeforeShown() async throws {
        let (window, host) = try makeHost()
        defer { window.isHidden = true }
        let previous = UIViewController()
        try await host.presentForTesting(previous)
        previous.dismiss(animated: true)
        let (lifecycle, controller, recorder) = makeLifecycle()
        lifecycle.present(from: host)
        #expect(lifecycle.isPresentedOrPending, "出すのを待っている間に、出していないことになりました")

        lifecycle.close(notifiesWillClose: false)

        try await waitUntil { recorder.didClose > 0 && host.presentedViewController == nil }
        #expect(recorder.willClose == 0)
        #expect(recorder.didClose == 1)
        #expect(recorder.didAppear == 0)
        #expect(controller.presentingViewController == nil)
    }

    /// 知らせなしに消えたあとに閉じるよう頼まれても、閉じ終わりは1回だけで、閉じる操作は何もしない。
    @Test func closeAfterDisappearingFinishesOnce() async throws {
        let (window, host) = try makeHost()
        defer { window.isHidden = true }
        let (lifecycle, controller, recorder) = makeLifecycle()
        try await presentAndWait(lifecycle, controller, from: host, recorder: recorder)
        try await controller.dismissForTesting()

        lifecycle.close(notifiesWillClose: true)

        try await waitUntil { recorder.didClose > 0 }
        #expect(recorder.didClose == 1)
        #expect(recorder.willClose == 1)
    }
}
