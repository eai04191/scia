#if DEBUG
import Foundation
import Testing
@testable import Scia

/// `scia-debug://status/<ステータス>?target=<経路>`で、どの通信に障害を起こすか。
struct DebugFaultTargetTests {
    @Test(arguments: [
        ("https://example.social/api/v1/timelines/home", DebugFaults.Target.api),
        ("https://example.social/oauth/token", .api),
        ("https://example.social/media_proxy/1/original", .mediaProxy),
        ("https://example.social/system/custom_emojis/1.png", .files),
        ("https://files.example.social/media/1.mp4", .files),
        ("https://api.fxtwitter.com/status/1", .x),
    ])
    func classifiesRequest(url: String, target: DebugFaults.Target) throws {
        #expect(DebugFaults.Target(of: URLRequest(url: try #require(URL(string: url)))) == target)
    }

    @Test func allCoversEveryTarget() {
        for target in DebugFaults.Target.allCases {
            #expect(DebugFaults.Target.all.covers(target))
        }
        #expect(!DebugFaults.Target.api.covers(.mediaProxy))
    }
}
#endif
