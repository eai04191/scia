import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct OperationFailureStoreTests {
    private let reason = ErrorPresentation(message: "サーバーが一時的に応答できません。", code: "HTTP 502")
    private let subject = OperationStatus.Subject(statusID: "2", displayedID: "1", url: URL(string: "https://example.social/@bob/1"), authorName: "Bob", excerpt: "本文")
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func credential(_ username: String) throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token-\(username)",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: username,
            username: username
        )
    }

    /// 起動し直してセッションを作り直しても、同じアカウントなら前の失敗が並ぶ。
    @Test func restoresFailuresForTheSameAccount() throws {
        let defaults = TestScratch.defaults("OperationFailureStoreTests")
        let failure = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }
            .recordFailure(title: "お気に入りを変更できませんでした", reason: reason, subject: subject)

        let restored = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }

        #expect(restored.failures == [failure])
    }

    /// ログインし直すボタンのためのアカウントは、読み戻した失敗には残らない。
    @Test func dropsTheLoggedOutAccountWhenRestoring() throws {
        let defaults = TestScratch.defaults("OperationFailureStoreTests")
        let loggedOut = ErrorPresentation(message: "ログアウトされています。", code: "HTTP 401", loggedOutAccount: RequestAccount(id: "1", handle: "alice@example.social"))
        OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }
            .recordFailure(title: "お気に入りを変更できませんでした", reason: loggedOut)

        let restored = try #require(OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }.failures.first)

        #expect(restored.reason == ErrorPresentation(message: "ログアウトされています。", code: "HTTP 401"))
    }

    @Test func keepsOnlyTheNewestFailuresInTheStore() throws {
        let defaults = TestScratch.defaults("OperationFailureStoreTests")
        let notices = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }
        for index in 0..<(OperationStatus.failureLimit + 5) {
            notices.recordFailure(title: "失敗\(index)", reason: reason)
        }

        let restored = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }

        #expect(restored.failures.count == OperationStatus.failureLimit)
        #expect(restored.failures.first?.title == "失敗\(OperationStatus.failureLimit + 4)")
        #expect(restored.failures.last?.title == "失敗5")
    }

    /// 失敗の行は投稿のIDで投稿を開くため、ほかのアカウントの失敗は並べない。
    @Test func separatesFailuresByAccount() throws {
        let defaults = TestScratch.defaults("OperationFailureStoreTests")
        OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }
            .recordFailure(title: "aliceの失敗", reason: reason)

        let bob = OperationStatus(store: .init(defaults: defaults, account: "bob@example.social")) { date }
        bob.recordFailure(title: "bobの失敗", reason: reason)

        #expect(bob.failures.map(\.title) == ["bobの失敗"])
        #expect(OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }.failures.map(\.title) == ["aliceの失敗"])
    }

    /// 同じアカウントを2つのウインドウで開いていても、片方の失敗でもう片方の失敗を上書きしない。
    @Test func keepsFailuresRecordedInAnotherWindow() throws {
        let defaults = TestScratch.defaults("OperationFailureStoreTests")
        let first = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }
        let second = OperationStatus(store: .init(defaults: defaults, account: "alice@example.social")) { date }

        first.recordFailure(title: "1つ目のウインドウ", reason: reason)
        second.recordFailure(title: "2つ目のウインドウ", reason: reason)

        #expect(second.failures.map(\.title) == ["2つ目のウインドウ", "1つ目のウインドウ"])
        #expect(first.failures.map(\.title) == ["1つ目のウインドウ"])
        first.reloadFailures()
        #expect(first.failures.map(\.title) == ["2つ目のウインドウ", "1つ目のウインドウ"])
    }

    @Test func logoutRemovesTheFailures() throws {
        let suite = TestScratch.suiteName("OperationFailureStoreTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let alice = try credential("alice")
        OperationStatus(store: .init(defaults: defaults, account: alice.handle)) { date }
            .recordFailure(title: "お気に入りを変更できませんでした", reason: reason)

        AccountScopedDefaults.removeData(of: alice, remaining: [], defaults: defaults, settings: AppSettings(defaults: defaults))

        #expect(OperationStatus(store: .init(defaults: defaults, account: alice.handle)) { date }.failures.isEmpty)
    }

    /// ログアウトでは値を消してからセッションを止めるため、止めた通信の失敗が届いても、消したキーに書き戻さない。
    @Test func stoppedStatusDoesNotSaveFailuresAfterLogout() throws {
        let suite = TestScratch.suiteName("OperationFailureStoreTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let alice = try credential("alice")
        let notices = OperationStatus(store: .init(defaults: defaults, account: alice.handle)) { date }
        notices.recordFailure(title: "お気に入りを変更できませんでした", reason: reason)

        AccountScopedDefaults.removeData(of: alice, remaining: [], defaults: defaults, settings: AppSettings(defaults: defaults))
        notices.stopSaving()
        notices.recordFailure(title: "編集を始められませんでした", reason: reason, subject: subject)

        #expect(OperationStatus(store: .init(defaults: defaults, account: alice.handle)) { date }.failures.isEmpty)
    }

    /// 何日も前の失敗も並ぶので、今日でなければ日付を、今年でなければ年も添える。
    @Test func timeTextAddsTheDayAndYearForOlderFailures() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let locale = Locale(identifier: "ja_JP")
        var recordedAt = date.addingTimeInterval(-365 * 24 * 60 * 60)
        let notices = OperationStatus { recordedAt }
        let lastYear = notices.recordFailure(title: "去年の失敗", reason: reason)
        recordedAt = date.addingTimeInterval(-24 * 60 * 60)
        let yesterday = notices.recordFailure(title: "昨日の失敗", reason: reason)
        recordedAt = date
        let today = notices.recordFailure(title: "今日の失敗", reason: reason)

        #expect(notices.timeText(of: today, calendar: calendar, locale: locale) == "23:13")
        #expect(notices.timeText(of: yesterday, calendar: calendar, locale: locale) == "9/20 23:13")
        #expect(notices.timeText(of: lastYear, calendar: calendar, locale: locale) == "2025/9/21 23:13")
    }

    /// シートを開いたまま日付が変わったら、今日の失敗として時刻だけを出していた行を描き直す。
    @Test func dayChangeRedrawsTheTimeText() {
        let notices = OperationStatus { date }
        let failure = notices.recordFailure(title: "お気に入りを変更できませんでした", reason: reason)
        let changed = Changed()
        withObservationTracking {
            _ = notices.timeText(of: failure)
        } onChange: {
            // onChangeは値を変更したスレッドで同期的に呼ばれるため、ここではMainActor上にいる。
            MainActor.assumeIsolated { changed.value = true }
        }

        notices.dayDidChange()

        #expect(changed.value)
    }
}

@MainActor
private final class Changed {
    var value = false
}
