import SciaCore
import Testing
import UIKit
@testable import Scia

/// テストが手で送るコマ。実際の時間では進まず、`advance(by:)`で送った分だけ、毎フレーム進める動きが進む。
@MainActor
final class ManualFrameSource: FrameSource {
    /// 1回に送る経過時間。
    static let frame: CFTimeInterval = 1.0 / 60

    private var tickers: [FrameTicker] = []
    /// コマごとに、送ったあとに行う処理。画面の描き換えの前と同じく、レイアウトを済ませるのに使う。
    var afterEachFrame: (() -> Void)?

    var isRunning: Bool { !tickers.isEmpty }

    func start(_ ticker: FrameTicker) {
        tickers.append(ticker)
    }

    func stop(_ ticker: FrameTicker) {
        tickers.removeAll { $0 === ticker }
    }

    /// `seconds`だけ、1コマずつ送る。
    func advance(by seconds: CFTimeInterval) {
        var remaining = seconds
        while remaining > 1e-9 {
            let length = min(Self.frame, remaining)
            step(length)
            remaining -= length
        }
    }

    /// 1コマ送る。
    func step(_ elapsed: CFTimeInterval = frame) {
        for ticker in tickers {
            ticker.receive(elapsed: elapsed)
        }
        afterEachFrame?()
    }

    /// 動いているものが止まるまで、1コマずつ送る。
    func runUntilStopped(sourceLocation: SourceLocation = #_sourceLocation) {
        var sent: CFTimeInterval = 0
        while isRunning {
            guard sent < 600 else {
                Issue.record("動きが止まらないまま、固まったとみなす上限を過ぎました", sourceLocation: sourceLocation)
                return
            }
            step()
            sent += Self.frame
        }
    }
}
