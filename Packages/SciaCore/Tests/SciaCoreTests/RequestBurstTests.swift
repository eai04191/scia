import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 短い間に異常な数のリクエストを送ったら、内訳を1度だけ返す。
struct RequestBurstTests {
    private let image = URL(string: "https://files.example/a.png")
    private let other = URL(string: "https://cdn.example/b.png")

    /// 数える長さの中で、`threshold`に達したときに返す。
    @Test func reportsWhenThresholdIsReachedWithinWindow() {
        var counter = RequestBurstCounter()
        let step = RequestBurstCounter.window / (RequestBurstCounter.threshold + 1)
        for index in 0..<(RequestBurstCounter.threshold - 1) {
            #expect(counter.record(url: image, purpose: .display, at: step * index) == nil)
        }
        let burst = counter.record(url: other, purpose: .prefetch, at: step * RequestBurstCounter.threshold)

        #expect(burst == RequestBurst(
            count: RequestBurstCounter.threshold,
            hosts: [.init(name: "files.example", count: RequestBurstCounter.threshold - 1), .init(name: "cdn.example", count: 1)],
            purposes: [.init(name: "display", count: RequestBurstCounter.threshold - 1), .init(name: "prefetch", count: 1)],
            distinctURLs: 2,
            topURL: .init(name: "https://files.example/a.png", count: RequestBurstCounter.threshold - 1)
        ))
    }

    /// 同じ数でも、数える長さより前に送ったものは数えない。
    @Test func ignoresRequestsOutsideWindow() {
        var counter = RequestBurstCounter()
        let step = RequestBurstCounter.window / RequestBurstCounter.threshold * 2
        for index in 0..<(RequestBurstCounter.threshold * 3) {
            #expect(counter.record(url: image, purpose: .display, at: step * index) == nil)
        }
    }

    /// 続いている間は`cooldown`ごとに1度だけ返し、ログを溢れさせない。
    @Test func reportsOncePerCooldownWhileBurstContinues() {
        var counter = RequestBurstCounter()
        let step = RequestBurstCounter.window / (RequestBurstCounter.threshold * 2)
        let total = RequestBurstCounter.cooldown * 2.5
        var reported: [Duration] = []
        var at = Duration.zero
        while at < total {
            if counter.record(url: image, purpose: .display, at: at) != nil {
                reported.append(at)
            }
            at += step
        }

        #expect(reported.count == 3)
        #expect(reported[1] - reported[0] >= RequestBurstCounter.cooldown)
        #expect(reported[1] - reported[0] < RequestBurstCounter.cooldown + step)
    }

    /// 包んだ口は、送る前に数え、達したら知らせる。
    @Test func transportReportsBurst() async throws {
        let bursts = BurstLog()
        let monitor = RequestBurstMonitor(clock: TestClock()) { bursts.append($0) }
        let transport = BurstMonitoringTransport(base: OKTransport(), monitor: monitor)
        for _ in 0..<RequestBurstCounter.threshold {
            _ = try await transport.send(URLRequest(url: try #require(image)))
        }

        #expect(bursts.counts == [RequestBurstCounter.threshold])
    }
}

private final class BurstLog: Sendable {
    private let bursts = Mutex<[RequestBurst]>([])
    var counts: [Int] { bursts.withLock { $0.map(\.count) } }
    func append(_ burst: RequestBurst) { bursts.withLock { $0.append(burst) } }
}

private struct OKTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
