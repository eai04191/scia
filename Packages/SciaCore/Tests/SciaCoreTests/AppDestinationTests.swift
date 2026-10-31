import Foundation
import Testing
@testable import SciaCore

struct AppDestinationTests {
    @Test func readsScreens() throws {
        let expected: [(String, AppDestination?)] = [
            ("scia://tab/home", .tab(.home)),
            ("scia://tab/scheduled", .tab(.scheduled)),
            ("scia://tab/list?id=12", .userTab(.list(id: "12"))),
            ("scia://tab/hashtag?name=scia", .userTab(.hashtag(name: "scia"))),
            ("scia://tab/profile?acct=bob%40example.com", .userTab(.profile(acct: "bob@example.com"))),
            ("scia://tab/account-hashtag?acct=bob&name=scia", .userTab(.accountHashtag(acct: "bob", name: "scia"))),
            ("scia://tab/account-hashtag?acct=bob", nil),
            ("scia://tab/unknown", nil),
            ("scia://settings", .settings(nil)),
            ("scia://settings/unknown", nil),
            ("scia://profile/@bob@example.com", .profile(acct: "bob@example.com")),
            ("scia://profile", nil),
            ("scia://my-profile", .myProfile),
            ("scia://profile-edit", .profileEdit),
            ("scia://thread?id=123", .thread(statusID: "123")),
            ("scia://thread", nil),
            ("scia://thread?id=", nil),
            ("scia://edit-history?id=123", .editHistory(statusID: "123")),
            ("scia://accounts/followers", .accounts(.followers(accountID: nil))),
            ("scia://accounts/following?id=9", .accounts(.following(accountID: "9"))),
            ("scia://accounts/favourited?id=123", .accounts(.favourited(statusID: "123"))),
            ("scia://accounts/reblogged?id=123", .accounts(.reblogged(statusID: "123"))),
            ("scia://accounts/favourited", nil),
            ("scia://hashtag?name=scia", .hashtag(name: "scia")),
            ("scia://account-hashtag?acct=bob&name=scia", .accountHashtag(acct: "bob", name: "scia")),
            ("scia://scheduled", .scheduled),
            ("scia://operation-status", .operationStatus),
            ("scia://note?acct=bob%40example.com", .note(acct: "bob@example.com")),
            ("scia://report?acct=bob", .report(acct: "bob")),
            ("scia://compose/tools", .compose(.tools)),
            ("scia://compose/language", .compose(.language)),
            ("scia://compose/schedule", .compose(.schedule)),
            ("scia://compose/emoji", .compose(.emoji)),
            ("scia://compose/media-picker", .compose(.mediaPicker)),
            ("scia://compose/attachment", .compose(.attachment(index: 0))),
            ("scia://compose/alt-text?index=2", .compose(.altText(index: 2))),
            ("scia://compose/crop?index=1", .compose(.crop(index: 1))),
            ("scia://compose/crop?index=-1", nil),
            ("scia://unknown", nil),
        ]
        for (string, destination) in expected {
            #expect(AppDestination(try #require(URL(string: string))) == destination, "\(string)")
        }
    }

    @Test(arguments: SettingsPage.allCases)
    func readsEverySettingsPage(_ page: SettingsPage) throws {
        let url = try #require(URL(string: "scia://settings/\(page.rawValue)"))
        #expect(AppDestination(url) == .settings(page))
    }

    @Test func pushesStorageBeforeMediaCache() {
        #expect(SettingsPage.viewedMediaCache.path == [.storage, .viewedMediaCache])
        #expect(SettingsPage.licenses.path == [.licenses])
    }

    /// ログには、誰の何を開いたかが分かるハンドルやIDを書かない。
    @Test func logsWithoutIdentifiers() {
        #expect(!AppDestination.note(acct: "bob@example.com").logDescription.contains("bob"))
        #expect(!AppDestination.thread(statusID: "123").logDescription.contains("123"))
    }

    @Test func matchesUserTabsLikeTheLayout() throws {
        let credential = Credential(instance: try #require(URL(string: "https://example.social")), accessToken: "", clientID: "", clientSecret: "", accountID: "1", username: "me")
        #expect(AppDestination.UserTab.profile(acct: "bob@example.social").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(AppDestination.UserTab.profile(acct: "@Bob").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(!AppDestination.UserTab.profile(acct: "bob@other.example").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(AppDestination.UserTab.hashtag(name: "ＳＣＩＡ").matches(.hashtag(name: "scia"), credential: credential))
        #expect(AppDestination.UserTab.accountHashtag(acct: "bob@example.social", name: "Café").matches(.accountHashtag(accountID: "2", acct: "bob", name: "cafe"), credential: credential))
        #expect(AppDestination.UserTab.list(id: "3").matches(.list(id: "3", title: "a"), credential: credential))
        #expect(!AppDestination.UserTab.list(id: "3").matches(.hashtag(name: "3"), credential: credential))
    }
}
