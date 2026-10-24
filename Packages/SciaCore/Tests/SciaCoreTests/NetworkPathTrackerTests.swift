import SciaCore
import Testing

struct NetworkPathTrackerTests {
    private let wifi = NetworkConditions(isConstrained: false, isExpensive: false)
    private let cellular = NetworkConditions(isConstrained: false, isExpensive: true)

    /// 見張り始めてすぐにつながっていると知らされても、戻ったとは数えない。
    @Test func firstSatisfiedPathIsNotRecovery() {
        var tracker = NetworkPathTracker()
        tracker.receive(isSatisfied: true, conditions: wifi)
        #expect(tracker.recoveryCount == 0)
    }

    /// つながっていない状態から、つながった状態に戻るたびに1つ数える。
    @Test func countsEachReturnFromUnsatisfied() {
        var tracker = NetworkPathTracker()
        tracker.receive(isSatisfied: false, conditions: wifi)
        tracker.receive(isSatisfied: true, conditions: wifi)
        #expect(tracker.recoveryCount == 1)
        tracker.receive(isSatisfied: false, conditions: wifi)
        tracker.receive(isSatisfied: true, conditions: cellular)
        #expect(tracker.recoveryCount == 2)
    }

    /// つながったまま回線の種類だけが変わっても、戻ったとは数えず、回線の状態だけを替える。
    @Test func conditionChangeWhileSatisfiedIsNotRecovery() {
        var tracker = NetworkPathTracker()
        tracker.receive(isSatisfied: true, conditions: wifi)
        tracker.receive(isSatisfied: true, conditions: cellular)
        #expect(tracker.recoveryCount == 0)
        #expect(tracker.conditions == cellular)
    }

    /// つながらないと続けて知らされても、戻ったときに数えるのは1つだけ。
    @Test func repeatedUnsatisfiedCountsOnce() {
        var tracker = NetworkPathTracker()
        tracker.receive(isSatisfied: false, conditions: wifi)
        tracker.receive(isSatisfied: false, conditions: wifi)
        tracker.receive(isSatisfied: true, conditions: wifi)
        #expect(tracker.recoveryCount == 1)
    }
}
