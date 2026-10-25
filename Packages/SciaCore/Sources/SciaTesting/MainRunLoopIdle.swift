import CoreFoundation
import Testing

/// メインのRunLoopが、積まれた処理（メインキューの処理、入力、レイアウトと描画の確定）を流し終えて手すきになるまで待つ。
///
/// RunLoopが次の入力を待つ待機に入る直前の知らせ（`beforeWaiting`）が来ただけでは、流し終えたとは限らない。RunLoopは、メインキューを流した次の回はメインキューを見ずに待機に入ろうとするので、
/// メインキューの処理が次の処理を積んでいると、処理が残ったまま知らせが来て、待機に入った直後に起こされる。
/// そこで、待機に入るたびに`quietLength`で起こすタイマーを掛け、その長さだけ待機が続いた（その間に何も届かなかった）ことが`quietTimesNeeded`回続いたら、手すきとみなす。
/// 処理が続けて積まれている間は、待機に入るたびにすぐ起こされるので、流し終えるまで戻らない。
///
/// `quietLength`より遅れて、ほかのスレッドやプロセスから届く処理は待たない。そうした処理を待つには、届いたことを条件にして`waitUntil`で待つ。
/// 待つ長さを延ばせば拾える処理は増えるが、1コマごとにその長さだけ実際の時間がかかり、時間を止めて手で進める利点がなくなる。
///
/// RunLoopが休まず回り続けて待機に入らないときは、`hangLimit`を過ぎたら失敗を残して戻る。
@MainActor
func waitUntilMainRunLoopIsIdle(sourceLocation: SourceLocation = #_sourceLocation) async {
    let waiter = MainRunLoopIdleWaiter(sourceLocation: sourceLocation)
    await withTaskCancellationHandler {
        await withCheckedContinuation { waiter.start($0) }
    } onCancel: {
        Task { @MainActor in waiter.finish() }
    }
}

@MainActor
private final class MainRunLoopIdleWaiter {
    private static let quietLength: CFTimeInterval = 0.001
    private static let quietTimesNeeded = 2
    /// 起こすタイマーを掛けていないときの、次に鳴る時刻と鳴る間隔。1回鳴ると止まるタイマーは掛け直せないので、繰り返し鳴るタイマーを遠い先に置いておく。
    private static let farFuture: CFTimeInterval = 60 * 60 * 24 * 365

    private let sourceLocation: SourceLocation
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CFRunLoopObserver?
    private var wakeTimer: CFRunLoopTimer?
    private var hangTimer: CFRunLoopTimer?
    private var sleptAt: CFAbsoluteTime?
    private var quietTimes = 0

    init(sourceLocation: SourceLocation) {
        self.sourceLocation = sourceLocation
    }

    func start(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
        let runLoop = CFRunLoopGetMain()
        let now = CFAbsoluteTimeGetCurrent()
        // 描画を確定する処理（Core Animationの知らせ）より後に呼ばれるよう、知らせの順番を最後にする。
        // 待ち終えるまで、この型は知らせとタイマーから握られる。待ち終えたら外すので、握り合いは残らない。
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated { self.handle(activity) }
        }
        let wakeTimer = CFRunLoopTimerCreateWithHandler(nil, now + Self.farFuture, Self.farFuture, 0, 0) { _ in }
        let hangTimer = CFRunLoopTimerCreateWithHandler(nil, now + Double(hangLimit.components.seconds), 0, 0, 0) { _ in
            MainActor.assumeIsolated { self.hang() }
        }
        self.observer = observer
        self.wakeTimer = wakeTimer
        self.hangTimer = hangTimer
        CFRunLoopAddObserver(runLoop, observer, .commonModes)
        CFRunLoopAddTimer(runLoop, wakeTimer, .commonModes)
        CFRunLoopAddTimer(runLoop, hangTimer, .commonModes)
    }

    func finish() {
        observer.map(CFRunLoopObserverInvalidate)
        wakeTimer.map(CFRunLoopTimerInvalidate)
        hangTimer.map(CFRunLoopTimerInvalidate)
        observer = nil
        wakeTimer = nil
        hangTimer = nil
        continuation?.resume()
        continuation = nil
    }

    private func handle(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity.contains(.beforeWaiting) {
            sleptAt = now
            wakeTimer.map { CFRunLoopTimerSetNextFireDate($0, now + Self.quietLength) }
        } else if activity.contains(.afterWaiting), let sleptAt {
            self.sleptAt = nil
            guard now - sleptAt >= Self.quietLength else {
                quietTimes = 0
                return
            }
            quietTimes += 1
            if quietTimes >= Self.quietTimesNeeded { finish() }
        }
    }

    private func hang() {
        Issue.record("メインのRunLoopが手すきにならないまま、固まったとみなす上限を過ぎました", sourceLocation: sourceLocation)
        finish()
    }
}
