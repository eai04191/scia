#if DEBUG
import Foundation
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

    @Test(arguments: [
        "scia-debug://tab/unknown",
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
