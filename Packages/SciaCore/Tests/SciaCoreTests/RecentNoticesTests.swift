import Foundation
import Testing
@testable import SciaCore

@MainActor
struct RecentNoticesTests {
    private let reason = ErrorPresentation(message: "サーバーで問題が起きています。", code: "HTTP 502")

    private func status(id: String, content: String = "<p>本文</p>", spoilerText: String = "", displayName: String = "Bob", reblogOf original: Status? = nil) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob@example.social", displayName: displayName, avatar: URL(string: "https://example.social/a.png")),
            content: content,
            spoilerText: spoilerText,
            url: URL(string: "https://example.social/@bob/\(id)"),
            reblog: original
        )
    }

    @Test func keepsOnlyTheNewestFailures() {
        let notices = RecentNotices()
        for index in 0..<(RecentNotices.failureLimit + 5) {
            notices.recordFailure(title: "失敗\(index)", reason: reason)
        }

        #expect(notices.failures.count == RecentNotices.failureLimit)
        #expect(notices.failures.first?.title == "失敗\(RecentNotices.failureLimit + 4)")
        #expect(notices.failures.last?.title == "失敗5")
    }

    @Test func failureKeepsReasonAndTime() {
        let date = Date(timeIntervalSince1970: 1000)
        let notices = RecentNotices { date }

        let failure = notices.recordFailure(title: "お気に入りを変更できませんでした", reason: reason, subject: .init(status(id: "1")))

        #expect(notices.failures == [failure])
        #expect(failure.reason == reason)
        #expect(failure.date == date)
        #expect(failure.subject?.statusID == "1")
    }

    @Test func subjectOfBoostPointsToBothIDsAndTheOriginalPage() {
        let original = status(id: "1", content: "<p>一行目</p><p>二行目</p>", displayName: "")
        let subject = RecentNotices.Subject(status(id: "2", reblogOf: original))

        #expect(subject.statusID == "2")
        #expect(subject.displayedID == "1")
        #expect(subject.url == original.url)
        // 表示名がなければacctにする。
        #expect(subject.authorName == "bob@example.social")
        #expect(subject.excerpt == "一行目 二行目")
    }

    @Test func subjectLeavesOutCustomEmojis() throws {
        let image = try #require(URL(string: "https://example.social/e.png"))
        let emoji = CustomEmoji(shortcode: "verified", url: image, staticUrl: image)
        let author = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob :verified:", avatar: nil, emojis: [emoji])
        let status = Status(id: "1", createdAt: Date(timeIntervalSince1970: 0), account: author, content: "<p>やった :verified: できた</p>", spoilerText: "", url: nil, emojis: [emoji])

        let subject = RecentNotices.Subject(status)

        #expect(subject.authorName == "Bob")
        #expect(subject.excerpt == "やった できた")
    }

    @Test func subjectOfSpoileredStatusShowsOnlyTheSpoiler() {
        let subject = RecentNotices.Subject(status(id: "1", content: "<p>隠した本文</p>", spoilerText: "ネタバレ"))

        #expect(subject.excerpt == "ネタバレ")
    }

    @Test func activitiesKeepTheirPlaceWhenUpdated() {
        let notices = RecentNotices()
        notices.update(.init(id: "a", title: "ダウンロード中"))
        notices.update(.init(id: "b", title: "アップロード中"))
        notices.update(.init(id: "a", title: "ダウンロード中", value: "42%"))

        #expect(notices.activities.map(\.id) == ["a", "b"])
        #expect(notices.activities.first?.value == "42%")

        notices.end("a")

        #expect(notices.activities.map(\.id) == ["b"])
    }

    @Test func stoppableActivityCanBeStoppedFromTheList() {
        let notices = RecentNotices()
        var stopped: [String] = []
        notices.update(.init(id: "a", title: "ダウンロード中"), onStop: { stopped.append("a") })
        notices.update(.init(id: "b", title: "アップロード中"))

        #expect(notices.activities.map(\.isStoppable) == [true, false])
        notices.stop("b")
        notices.stop("a")
        #expect(stopped == ["a"])

        // 書き換えで止める操作を外したら、もう止められない。
        notices.update(.init(id: "a", title: "ダウンロード中", value: "100%"))
        notices.stop("a")
        #expect(stopped == ["a"])
        #expect(notices.activities.first?.isStoppable == false)
    }

    @Test func persistentChoicePrefersNewestFailureThenNewestProgress() {
        struct Item: Equatable {
            let name: String
            let isFailure: Bool
        }
        let items = [
            Item(name: "古い失敗", isFailure: true),
            Item(name: "新しい失敗", isFailure: true),
            Item(name: "処理の途中", isFailure: false),
        ]

        let failure = PersistentNoticeChoice.choose(items, isFailure: \.isFailure)
        #expect(failure?.item.name == "新しい失敗")
        #expect(failure?.others == 2)

        let progress = PersistentNoticeChoice.choose([Item(name: "前", isFailure: false), Item(name: "後", isFailure: false)], isFailure: \.isFailure)
        #expect(progress?.item.name == "後")
        #expect(progress?.others == 1)

        #expect(PersistentNoticeChoice.choose([Item](), isFailure: \.isFailure) == nil)
    }
}
