import Foundation
import Testing
@testable import SciaCore

struct UserActionTests {
    @Test(arguments: [
        UserAction.selectTab("home"),
        .reselectTab("notifications"),
        .scroll(ScrollRecord(screen: "timeline", direction: .down, pages: 1.25, duration: 0.5, hitches: HitchCounter.Summary(droppedFrames: 3, hitchTime: 0.048))),
        .scroll(ScrollRecord(screen: "notifications", direction: .up, pages: 0.75, duration: 1.5, hitches: HitchCounter.Summary(droppedFrames: 0, hitchTime: 0))),
        .scrollToTop(screen: "timeline"),
        .tapNewArrivals(screen: "timeline"),
        .tapGap(screen: "profile"),
        .openMenu(screen: "timeline"),
        .openViewer(count: 4, index: 2),
        .closeViewer(.drag),
        .closeViewer(.button),
        .openProfile,
        .reply,
        .toggleFavourite,
        .toggleReblog,
        .expandCompose,
        .submitPost,
        .enterForeground,
        .enterBackground,
    ])
    func roundTripsThroughLogMessage(action: UserAction) {
        #expect(UserAction(logMessage: action.logMessage) == action)
    }

    @Test(arguments: ["", "unknown", "scroll timeline", "scroll timeline sideways 1.00 0.50 0 0.000", "viewer.open 4", "viewer.open four 1", "viewer.close swipe", "profile.open extra"])
    func rejectsMalformedMessages(message: String) {
        #expect(UserAction(logMessage: message) == nil)
    }
}

struct OperationTimelineTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_000_000)

    private func log(_ secondsBefore: TimeInterval, _ action: UserAction) -> LogLine {
        LogLine(date: capturedAt.addingTimeInterval(-secondsBefore), category: UserAction.logCategory, level: "info", message: action.logMessage)
    }

    @Test func listsActionsWithinWindowOldestFirst() {
        let logs = [
            log(300, .selectTab("notifications")),
            log(40, .selectTab("home")),
            LogLine(date: capturedAt.addingTimeInterval(-30), category: "timeline", level: "info", message: "home fill done added=1 gaps=0"),
            log(20, .openViewer(count: 4, index: 0)),
            log(10, .closeViewer(.drag)),
            log(-5, .openProfile),
        ]

        #expect(OperationTimeline.steps(from: logs, capturedAt: capturedAt).map(\.line) == [
            "40秒前 ホームのタブを選んだ",
            "20秒前 4件のメディアの1件目をビューアで開いた",
            "10秒前 ビューアをドラッグして閉じた",
        ])
    }

    @Test func mergesConsecutiveSameActions() {
        let logs = [
            log(50, .tapNewArrivals(screen: "timeline")),
            log(45, .tapNewArrivals(screen: "timeline")),
            log(40, .tapNewArrivals(screen: "timeline")),
            log(30, .reselectTab("home")),
            log(20, .tapNewArrivals(screen: "timeline")),
        ]

        #expect(OperationTimeline.steps(from: logs, capturedAt: capturedAt).map(\.line) == [
            "50秒前 ホームの新着ボタンを押した（3回）",
            "30秒前 ホームのタブをもう一度押した",
            "20秒前 ホームの新着ボタンを押した",
        ])
    }

    /// スクロールは向きや量で見分けられるよう、同じ画面でも1回ずつ並べる。
    @Test func describesEachScroll() {
        let logs = [
            log(30, .scroll(ScrollRecord(screen: "timeline", direction: .down, pages: 2.34, duration: 1.21, hitches: HitchCounter.Summary(droppedFrames: 0, hitchTime: 0)))),
            log(20, .scroll(ScrollRecord(screen: "timeline", direction: .up, pages: 0.5, duration: 0.4, hitches: HitchCounter.Summary(droppedFrames: 4, hitchTime: 0.0667)))),
        ]

        #expect(OperationTimeline.steps(from: logs, capturedAt: capturedAt).map(\.line) == [
            "30秒前 ホームを下へ2.3画面分スクロールした（1.2秒）",
            "20秒前 ホームを上へ0.5画面分スクロールした（0.4秒、落ちたフレーム4・計67ms）",
        ])
    }

    @Test func includesFailuresWithoutTheirMessage() {
        let logs = [
            log(30, .tapGap(screen: "timeline")),
            LogLine(date: capturedAt.addingTimeInterval(-28), category: "network", level: "error", message: "request failed GET /api/v1/timelines/home HTTP 502"),
        ]

        let steps = OperationTimeline.steps(from: logs, capturedAt: capturedAt)
        #expect(steps.map(\.line) == [
            "30秒前 ホームの読み込んでいない部分を押した",
            "28秒前 アプリ: networkで失敗が記録された",
        ])
        #expect(steps.map(\.isAppEvent) == [false, true])
    }
}

struct ScrollRecordTests {
    @Test func measuresDirectionAndPagesFromOffsets() {
        let none = HitchCounter.Summary(droppedFrames: 0, hitchTime: 0)

        let down = ScrollRecord(screen: "timeline", startOffset: 100, endOffset: 1300, viewportHeight: 800, duration: 1, hitches: none)
        #expect(down.direction == .down)
        #expect(down.pages == 1.5)

        let up = ScrollRecord(screen: "timeline", startOffset: 1300, endOffset: 900, viewportHeight: 800, duration: 1, hitches: none)
        #expect(up.direction == .up)
        #expect(up.pages == 0.5)
    }
}

struct HitchCounterTests {
    /// 60Hzで、予定の時刻どおりに呼ばれ続けた場合。
    private let frame = 1.0 / 60

    @Test func countsNothingWhenOnTime() {
        var counter = HitchCounter()
        for index in 0..<10 {
            let timestamp = Double(index) * frame
            counter.record(timestamp: timestamp, targetTimestamp: timestamp + frame)
        }

        #expect(counter.summary == HitchCounter.Summary(droppedFrames: 0, hitchTime: 0))
    }

    @Test func countsFramesMissedAfterTheTarget() throws {
        var counter = HitchCounter()
        counter.record(timestamp: 0, targetTimestamp: frame)
        // 予定は1フレーム後だったが、3フレーム後に呼ばれた。
        counter.record(timestamp: frame * 3, targetTimestamp: frame * 4)
        counter.record(timestamp: frame * 4, targetTimestamp: frame * 5)

        #expect(counter.summary.droppedFrames == 2)
        #expect(abs(counter.summary.hitchTime - frame * 2) < 1e-9)
    }

    @Test func ignoresJitterSmallerThanHalfAFrame() {
        var counter = HitchCounter()
        counter.record(timestamp: 0, targetTimestamp: frame)
        counter.record(timestamp: frame * 1.3, targetTimestamp: frame * 2.3)

        #expect(counter.summary.droppedFrames == 0)
    }
}
