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
    }

    @Test func readsProgressNotice() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/progress"))) == .progressNotice(seconds: 60))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/progress?seconds=5"))) == .progressNotice(seconds: 5))
        #expect(DebugURL(try #require(URL(string: "scia-debug://notice/other"))) == nil)
    }

    @Test func readsAgentNavigation() throws {
        #expect(DebugURL(try #require(URL(string: "scia-debug://dump"))) == .dump)
        #expect(DebugURL(try #require(URL(string: "scia-debug://reset"))) == .reset)
        #expect(DebugURL(try #require(URL(string: "scia-debug://settings"))) == .settings)
        #expect(DebugURL(try #require(URL(string: "scia-debug://tuning"))) == .tuning)
        #expect(DebugURL(try #require(URL(string: "scia-debug://tab/home"))) == .tab(.home))
        #expect(DebugURL(try #require(URL(string: "scia-debug://tab/notifications"))) == .tab(.notifications))
        #expect(DebugURL(try #require(URL(string: "scia-debug://viewer"))) == .viewer(index: 0))
        #expect(DebugURL(try #require(URL(string: "scia-debug://viewer?index=2"))) == .viewer(index: 2))
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
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/502"))) == .status(502, retryAfter: nil))
        #expect(DebugURL(try #require(URL(string: "scia-debug://status/429?retry-after=30"))) == .status(429, retryAfter: 30))
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
        "scia-debug://status/600",
        "scia-debug://regenerating/unknown",
        "scia-debug://streaming/unknown",
        "scia-debug://ticker-loop/unknown",
        "scia-debug://unsupported/unknown",
        "scia-debug://notice/progress?seconds=0",
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
