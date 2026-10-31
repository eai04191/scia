#if DEBUG
import Foundation
import SciaCore
import Testing
@testable import Scia

struct DebugURLTests {
    @Test(arguments: DebugDummyPost.allCases)
    func readsEveryDummyPost(_ post: DebugDummyPost) throws {
        let url = try #require(URL(string: "scia-debug://dummy/\(post.rawValue)"))
        #expect(DebugURL(url) == .dummy(post))
    }

    @Test func readsCatalog() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://catalog"))) == .catalog(nil))
    }

    @Test(arguments: CatalogComponent.allCases)
    func readsEveryCatalogComponent(_ component: CatalogComponent) throws {
        let url = try #require(URL(string: "scia-debug://catalog/\(component.rawValue)"))
        #expect(DebugURL(url) == .catalog(component))
    }

    @Test func readsSlowDownload() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://download/slow"))) == .slowDownload(seconds: 10))
        #expect(DebugURL(try #require(URL(string: "scia-debug://download/slow?seconds=30"))) == .slowDownload(seconds: 30))
        #expect(DebugURL(try #require(URL(string: "scia-debug://download/normal"))) == .slowDownload(seconds: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://menu-icons/slow"))) == .slowMenuIcons(seconds: 3))
        #expect(DebugURL(try #require(URL(string: "scia-debug://menu-icons/slow?seconds=10"))) == .slowMenuIcons(seconds: 10))
        #expect(DebugURL(try #require(URL(string: "scia-debug://menu-icons/normal"))) == .slowMenuIcons(seconds: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://lookup/slow"))) == .slowLookups(seconds: 3))
        #expect(DebugURL(try #require(URL(string: "scia-debug://lookup/slow?seconds=10"))) == .slowLookups(seconds: 10))
        #expect(DebugURL(try #require(URL(string: "scia-debug://lookup/normal"))) == .slowLookups(seconds: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://upload/slow"))) == .slowUploads(seconds: 5))
        #expect(DebugURL(try #require(URL(string: "scia-debug://upload/slow?seconds=20"))) == .slowUploads(seconds: 20))
        #expect(DebugURL(try #require(URL(string: "scia-debug://upload/normal"))) == .slowUploads(seconds: nil))
    }

    @Test func readsNotice() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/progress"))) == .progressNotice(seconds: 60, title: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/progress?seconds=5"))) == .progressNotice(seconds: 5, title: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/progress?title=%E9%95%B7%E3%81%84"))) == .progressNotice(seconds: 60, title: "長い"))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/transient?title=%E9%95%B7%E3%81%84"))) == .transientNotice(title: "長い", seconds: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/transient?title=a&seconds=30"))) == .transientNotice(title: "a", seconds: 30))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/other"))) == nil)
    }

    @Test func readsAgentNavigation() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://dump"))) == .dump)
        #expect(DebugURL(try #require(URL(string: "scia-debug://reset"))) == .reset)
        #expect(DebugURL(try #require(URL(string: "scia-debug://settings"))) == .settings(nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://tuning"))) == .tuning)
        #expect(DebugURL(try #require(URL(string: "scia-debug://tab/home"))) == .tab(.home))
        #expect(DebugURL(try #require(URL(string: "scia-debug://tab/notifications"))) == .tab(.notifications))
        #expect(DebugURL(try #require(URL(string: "scia-debug://viewer"))) == .viewer(index: 0))
        #expect(DebugURL(try #require(URL(string: "scia-debug://viewer?index=2"))) == .viewer(index: 2))
    }

    @Test(arguments: SettingsPage.allCases)
    func readsEverySettingsPage(_ page: SettingsPage) throws {
        let url = try #require(URL(string: "scia-debug://settings/\(page.rawValue)"))
        #expect(DebugURL(url) == .settings(page))
    }

    @Test func readsScreens() throws {
        let expected: [(String, DebugURL?)] = [
            ("scia-debug://settings/unknown", nil),
            ("scia-debug://my-profile", .myProfile),
            ("scia-debug://tab/list?id=12", .userTab(.list(id: "12"))),
            ("scia-debug://tab/hashtag?name=scia", .userTab(.hashtag(name: "scia"))),
            ("scia-debug://tab/profile?acct=bob%40example.com", .userTab(.profile(acct: "bob@example.com"))),
            ("scia-debug://tab/account-hashtag?acct=bob&name=scia", .userTab(.accountHashtag(acct: "bob", name: "scia"))),
            ("scia-debug://tab/account-hashtag?acct=bob", nil),
            ("scia-debug://tab/unknown", nil),
            ("scia-debug://thread?id=123", .thread(statusID: "123")),
            ("scia-debug://thread", nil),
            ("scia-debug://edit-history?id=123", .editHistory(statusID: "123")),
            ("scia-debug://accounts/followers", .accounts(.followers(accountID: nil))),
            ("scia-debug://accounts/following?id=9", .accounts(.following(accountID: "9"))),
            ("scia-debug://accounts/favourited?id=123", .accounts(.favourited(statusID: "123"))),
            ("scia-debug://accounts/reblogged?id=123", .accounts(.reblogged(statusID: "123"))),
            ("scia-debug://accounts/favourited", nil),
            ("scia-debug://scheduled", .scheduled),
            ("scia-debug://operation-status", .operationStatus),
            ("scia-debug://discomfort-report", .discomfortReport),
            ("scia-debug://note?acct=bob%40example.com", .note(acct: "bob@example.com")),
            ("scia-debug://report?acct=bob", .report(acct: "bob")),
            ("scia-debug://compose/tools", .composeSheet(.tools)),
            ("scia-debug://compose/language", .composeSheet(.language)),
            ("scia-debug://compose/schedule", .composeSheet(.schedule)),
            ("scia-debug://compose/emoji", .composeSheet(.emoji)),
            ("scia-debug://compose/media-picker", .composeSheet(.mediaPicker)),
            ("scia-debug://compose/attachment", .composeSheet(.attachment(index: 0))),
            ("scia-debug://compose/attachment?index=2", .composeSheet(.attachment(index: 2))),
        ]
        for (string, url) in expected {
            #expect(DebugURL(try #require(URL(string: string))) == url, "\(string)")
        }
    }

    @Test func matchesUserTabsLikeTheLayout() throws {
        let credential = Credential(instance: try #require(URL(string: "https://example.social")), accessToken: "", clientID: "", clientSecret: "", accountID: "1", username: "me")
        #expect(DebugURL.UserTab.profile(acct: "bob@example.social").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(DebugURL.UserTab.profile(acct: "@Bob").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(!DebugURL.UserTab.profile(acct: "bob@other.example").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(DebugURL.UserTab.hashtag(name: "ＳＣＩＡ").matches(.hashtag(name: "scia"), credential: credential))
        #expect(DebugURL.UserTab.accountHashtag(acct: "bob@example.social", name: "Café").matches(.accountHashtag(accountID: "2", acct: "bob", name: "cafe"), credential: credential))
        #expect(DebugURL.UserTab.list(id: "3").matches(.list(id: "3", title: "a"), credential: credential))
        #expect(!DebugURL.UserTab.list(id: "3").matches(.hashtag(name: "3"), credential: credential))
    }

    @Test func readsProfileEdit() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://profile-edit"))) == .profileEdit(note: nil, field: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://profile-edit?note=%3Ablob"))) == .profileEdit(note: ":blob", field: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://profile-edit?field=%40bob"))) == .profileEdit(note: nil, field: "@bob"))
    }

    @Test func readsArrivalHold() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://arrivals/hold"))) == .holdArrivals(true))
        #expect(DebugURL(try #require(URL(string: "scia-debug://arrivals/release"))) == .holdArrivals(false))
    }

    @Test func readsFixedURLs() throws {
        let expected: [(String, DebugURL)] = [
            ("scia-debug://dummy-session", .dummySession),
            ("scia-debug://unauthorized", .unauthorized),
            ("scia-debug://unreadable", .unreadable),
            ("scia-debug://status/ok", .statusCleared),
            ("scia-debug://regenerating/on", .regenerating(true)),
            ("scia-debug://regenerating/off", .regenerating(false)),
            ("scia-debug://streaming/offline", .streaming(isOnline: false)),
            ("scia-debug://streaming/online", .streaming(isOnline: true)),
            ("scia-debug://media-limits/server", .mediaLimits(nil)),
            ("scia-debug://ticker-loop/on", .statusBarTickerLoop(true)),
            ("scia-debug://ticker-loop/off", .statusBarTickerLoop(false)),
        ]
        for (string, debugURL) in expected {
            #expect(DebugURL(try #require(URL(string: string))) == debugURL, "\(string)")
            #expect(DebugURL(try #require(URL(string: string + "/"))) == debugURL, "\(string)/")
        }
    }

    @Test(arguments: OptionalFeature.allCases)
    func readsEveryUnsupportedFeature(_ feature: OptionalFeature) throws {
        let url = try #require(URL(string: "scia-debug://unsupported/\(feature.rawValue)"))
        #expect(DebugURL(url) == .unsupported(feature))
    }

    @Test func readsStatus() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/502"))) == .status(502, retryAfter: nil, target: .api))
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/429?retry-after=30"))) == .status(429, retryAfter: 30, target: .api))
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/429?retry-after=30&target=media-proxy"))) == .status(429, retryAfter: 30, target: .mediaProxy))
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/503?target=streaming"))) == .status(503, retryAfter: nil, target: .streaming))
    }

    @Test func readsMediaLimits() throws {
        let url = try #require(URL(string: "scia-debug://media-limits?image-size=1000000&video-frame-rate=30"))
        #expect(DebugURL(url) == .mediaLimits(MediaLimits(
            imageSizeLimit: 1_000_000,
            imageMatrixLimit: nil,
            videoSizeLimit: nil,
            videoMatrixLimit: nil,
            videoFrameRateLimit: 30
        )))
    }

    @Test(arguments: [
        "scia-debug://status/99",
        "scia-debug://status/429?target=unknown",
        "scia-debug://status/600",
        "scia-debug://regenerating/unknown",
        "scia-debug://streaming/unknown",
        "scia-debug://ticker-loop/unknown",
        "scia-debug://unsupported/unknown",
        "scia-debug://notice/progress?seconds=0",
        "scia-debug://notice/transient",
        "scia-debug://notice/transient?title=a&seconds=0",
        "scia-debug://notice/progress?seconds=nan",
        "scia-debug://notice/transient?title=a&seconds=inf",
        "scia-debug://tab/unknown",
        "scia-debug://arrivals/unknown",
        "scia-debug://viewer?index=-1",
        "scia-debug://download/unknown",
        "scia-debug://catalog/unknown",
        "scia-debug://dummy/unknown",
        "scia-debug://unknown/images",
        "net.mizle.scia://dummy/images",
    ])
    func rejectsUnknownURL(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(DebugURL(url) == nil)
    }
}
#endif
