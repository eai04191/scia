import Foundation
@testable import SciaCore
import Testing

/// 投稿欄から送った結果を、セッションの一覧へ配る。
@MainActor
struct SessionStatusesTests {
    /// 渡された変化を記録する一覧。`receivesPosted`なら、送った投稿を受け取る。
    private final class RecordingList: SessionStatusList {
        var updated: [Status] = []
        var posted: [Status.ID] = []
        let receivesPosted: Bool
        private let held: Status

        init(holding held: Status, receivesPosted: Bool) {
            self.held = held
            self.receivesPosted = receivesPosted
        }

        func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
            guard id == held.id else { return }
            updated.append(transform(held))
        }

        func removeStatus(_ id: Status.ID) {}

        func receivePosted(_ status: Status) {
            guard receivesPosted else { return }
            posted.append(status.id)
        }
    }

    /// 受け取らない一覧。`receivePosted(_:)`を書かなければ、何もしない。
    private final class PlainList: SessionStatusList {
        func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {}
        func removeStatus(_ id: Status.ID) {}
    }

    private func status(id: String, content: String = "") -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: nil),
            content: content,
            spoilerText: "",
            url: nil
        )
    }

    /// 投稿したら、受け取る一覧にだけ足す。ほかの一覧の投稿は変えない。
    @Test func postedGoesToReceivingLists() {
        let statuses = SessionStatuses()
        let home = RecordingList(holding: status(id: "1"), receivesPosted: true)
        let local = RecordingList(holding: status(id: "1"), receivesPosted: false)
        statuses.register(home)
        statuses.register(local)
        statuses.register(PlainList())

        statuses.reflect(.posted(status(id: "2")), usingTagsIn: nil)

        #expect(home.posted == ["2"])
        #expect(local.posted.isEmpty)
        #expect(home.updated.isEmpty && local.updated.isEmpty)
    }

    /// 編集したら、その投稿を持つ一覧すべてで編集後の投稿に置き換え、引用元としても編集したことにする。
    @Test func editedReplacesEverywhereAndQuoteSources() {
        let statuses = SessionStatuses()
        let lists = [RecordingList(holding: status(id: "1"), receivesPosted: true), RecordingList(holding: status(id: "1"), receivesPosted: false)]
        lists.forEach(statuses.register)
        var quoteChanges: [QuoteSourceChange] = []
        statuses.onQuoteSourcesChange = { _, change in quoteChanges.append(change) }

        statuses.reflect(.edited(status(id: "1", content: "<p>直した</p>")), usingTagsIn: nil)

        #expect(lists.map { $0.updated.map(\.content) } == [["<p>直した</p>"], ["<p>直した</p>"]])
        #expect(lists.allSatisfy { $0.posted.isEmpty })
        #expect(quoteChanges == [.status("1")])
    }
}
