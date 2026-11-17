import Foundation
import Testing
@testable import SciaCore

@Suite struct StatusFixedHeightPartsTests {
    private func status(id: String = "1", content: String = "<p>本文</p>", reblog: Status? = nil) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil),
            content: content,
            spoilerText: "",
            url: nil,
            reblog: reblog
        )
    }

    /// 自分の状態と件数だけが変わった投稿を、高さの変わらない変化として見分ける。本文も変わっていれば当たらず、同じ投稿でも当たらない。
    /// ブーストでは、元の投稿の中身で比べる。
    @Test func detectsFixedHeightOnlyChange() {
        let before = status()
        let edited = status(content: "<p>編集した本文</p>")
        #expect(before.settingFavourited(true).differsOnlyInFixedHeightParts(from: before))
        #expect(before.settingReblogged(true).settingBookmarked(true).differsOnlyInFixedHeightParts(from: before))
        #expect(!before.differsOnlyInFixedHeightParts(from: before))
        #expect(!edited.differsOnlyInFixedHeightParts(from: before))
        #expect(!edited.settingFavourited(true).differsOnlyInFixedHeightParts(from: before))

        let boost = status(id: "2", reblog: before)
        #expect(boost.replacingReblog(with: before.settingFavourited(true)).differsOnlyInFixedHeightParts(from: boost))
        #expect(!boost.replacingReblog(with: edited).differsOnlyInFixedHeightParts(from: boost))
    }
}
