import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct MediaPrefetchTests {
    private func attachment(_ id: String, _ type: MediaAttachment.Kind, url: String?, remoteUrl: String? = nil) -> MediaAttachment {
        MediaAttachment(id: id, type: type, url: url.flatMap(URL.init(string:)), previewUrl: URL(string: "https://example.social/small/\(id).png"), remoteUrl: remoteUrl.flatMap(URL.init(string:)))
    }

    /// ビューアと同じく元の画像を読み、自分のサーバーが持っていなければ他のサーバーの元の画像を読む。画像のほかの種類は読まない。
    @Test func readsViewerImagesOnly() {
        let urls = MediaPrefetch.urls(of: [
            attachment("1", .image, url: "https://example.social/original/1.png"),
            attachment("2", .video, url: "https://example.social/original/2.mp4"),
            attachment("3", .gifv, url: "https://example.social/original/3.mp4"),
            attachment("4", .image, url: nil, remoteUrl: "https://remote.example/4.png"),
            attachment("5", .image, url: "https://example.social/original/1.png"),
        ])
        #expect(urls.map(\.absoluteString) == ["https://example.social/original/1.png", "https://remote.example/4.png"])
    }

    /// 同時には1つしか読まず、読み終えたら次を読む。
    @Test func loadsOneAtATimeInOrder() async throws {
        let gates = ["a": Gate(), "b": Gate()]
        var started: [String] = []
        let queue = PrefetchQueue<String>(scope: TaskScope()) { item in
            started.append(item)
            try? await gates[item]?.wait()
        }
        queue.replace(with: ["a", "b"])
        try await waitUntil { gates["a"]?.waiterCount == 1 }
        #expect(started == ["a"])

        gates["a"]?.open()
        try await waitUntil { gates["b"]?.waiterCount == 1 }
        #expect(started == ["a", "b"])
        gates["b"]?.open()
        try await waitUntil { !queue.isLoading }
    }

    /// 並びから外れたものは止め、新しい並びを先頭から読む。読んでいる途中のものが新しい並びにあれば、止めずに読み終える。
    @Test func replacingStopsItemsThatLeftAndKeepsTheCurrentOne() async throws {
        let gate = Gate()
        var started: [String] = []
        var cancelled: [String] = []
        let queue = PrefetchQueue<String>(scope: TaskScope()) { item in
            started.append(item)
            do {
                try await gate.wait()
            } catch {
                cancelled.append(item)
            }
        }
        queue.replace(with: ["a", "b"])
        try await waitUntil { gate.waiterCount == 1 }

        queue.replace(with: ["c", "a"])
        #expect(cancelled.isEmpty)
        queue.replace(with: ["c"])
        try await waitUntil { cancelled == ["a"] && started == ["a", "c"] && gate.waiterCount == 1 }

        gate.open()
        try await waitUntil { !queue.isLoading }
        #expect(started == ["a", "c"])
    }

    /// 空にしたら、読んでいる途中のものも止め、何も残さない。
    @Test func clearingStopsEverything() async throws {
        let gate = Gate()
        var cancelled = false
        let queue = PrefetchQueue<String>(scope: TaskScope()) { _ in
            do {
                try await gate.wait()
            } catch {
                cancelled = true
            }
        }
        queue.replace(with: ["a", "b"])
        try await waitUntil { gate.waiterCount == 1 }

        queue.replace(with: [])
        #expect(!queue.isLoading)
        try await waitUntil { cancelled }
        #expect(gate.waiterCount == 0)
    }

    /// 持ち主を閉じたら、読んでいる途中のものを止め、残りも読まない。ログアウトしたアカウントの画像を読まないため。
    @Test func closingTheScopeStopsTheRest() async throws {
        let scope = TaskScope()
        let gate = Gate()
        var started: [String] = []
        let queue = PrefetchQueue<String>(scope: scope) { item in
            started.append(item)
            try? await gate.wait()
        }
        queue.replace(with: ["a", "b"])
        try await waitUntil { gate.waiterCount == 1 }

        scope.close()
        try await waitUntil { scope.runningCount == 0 }
        #expect(started == ["a"])
        #expect(!queue.isLoading)
        queue.replace(with: ["c"])
        #expect(!queue.isLoading)
        #expect(scope.runningCount == 0)
    }
}
