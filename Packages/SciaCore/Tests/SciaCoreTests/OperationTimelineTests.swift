import Foundation
import Testing
@testable import SciaCore

struct UserActionTests {
    @Test(arguments: [
        UserAction.selectTab("home"),
        .reselectTab("notifications"),
        .scroll(screen: "timeline"),
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

    @Test(arguments: ["", "unknown", "viewer.open 4", "viewer.open four 1", "viewer.close swipe", "profile.open extra"])
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
            log(50, .scroll(screen: "timeline")),
            log(45, .scroll(screen: "timeline")),
            log(40, .scroll(screen: "timeline")),
            log(30, .tapNewArrivals(screen: "timeline")),
            log(20, .scroll(screen: "timeline")),
        ]

        #expect(OperationTimeline.steps(from: logs, capturedAt: capturedAt).map(\.line) == [
            "50秒前 ホームをスクロールした（3回）",
            "30秒前 ホームの新着ボタンを押した",
            "20秒前 ホームをスクロールした",
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
