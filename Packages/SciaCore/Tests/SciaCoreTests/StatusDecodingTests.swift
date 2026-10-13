import Foundation
import Testing
@testable import SciaCore

struct StatusDecodingTests {
    @Test func decodesStatusFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        let status = try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))

        #expect(status.id == "113000000000000001")
        #expect(status.account.displayName == "Alice :blobcat:")
        #expect(status.spoilerText.isEmpty)
        #expect(abs(status.createdAt.timeIntervalSince1970 - 1_791_861_705.123) < 0.001)
        #expect(status.visibility == .public)
        // 自分の操作を表す項目が無いレスポンスでも読める。
        #expect(!status.favourited)
        #expect(status.favouritesCount == 0)
    }

    @Test func settingFavouritedAdjustsCountOnlyWhenChanged() throws {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        let status = try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))

        let favourited = status.settingFavourited(true)
        #expect(favourited.favouritesCount == 1)
        #expect(favourited.settingFavourited(true) == favourited)
        #expect(favourited.settingFavourited(false).favouritesCount == 0)
        // 件数が0のまま外しても負にしない。
        #expect(status.settingReblogged(true).settingReblogged(false).settingReblogged(false).reblogsCount == 0)
    }

    @Test func decodesDateWithoutFractionalSeconds() throws {
        struct Wrapper: Decodable { let createdAt: Date }
        let json = Data(#"{"created_at":"2026-10-13T03:21:45Z"}"#.utf8)
        let wrapper = try MastodonDecoder.make().decode(Wrapper.self, from: json)

        #expect(wrapper.createdAt == Date(timeIntervalSince1970: 1_791_861_705))
    }
}
