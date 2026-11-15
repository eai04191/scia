import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// actorの上で、外から開けるまで止まる。置く処理と分け直しが重なる順番を、テストで決めるのに使う。
private final class ActorHold: Sendable {
    let entered = Gate()
    private let semaphore = DispatchSemaphore(value: 0)

    func hold() {
        entered.open()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

extension MediaFileCache {
    fileprivate func hold(_ block: ActorHold) { block.hold() }
}

extension EmojiImageFiles {
    fileprivate func hold(_ block: ActorHold) { block.hold() }
}

/// Aに置くのと、ログアウトで応答を消したときの分け直しが重なっても、応答に載っていない画像をAに残さない。
@Suite(.scratch)
struct EmojiImageFilesRaceTests {
    private let root = TestScratch.url("EmojiImageFilesRaceTests")

    /// 応答に載っていると見て置き始めたあと、置き終える前に分け直しで外れたら、Aから外す。
    /// 残すと、次の分け直しまで、上限にも「キャッシュを消去」にもかからないため。
    @Test(arguments: [true, false])
    func doesNotKeepImageThatLeftListWhileStoring(prefetch: Bool) async throws {
        let url = try #require(URL(string: "https://example.social/emoji.png"))
        let checkedCapacity = Gate()
        let files = EmojiImageFiles(directory: root.appending(path: "images"), sharingDirectory: root.appending(path: "sharing")) {
            checkedCapacity.open()
            return Int.max
        }
        await files.updateListed([url])
        _ = try await files.listed.store(Data([1]), named: "emoji.png", for: url, generation: 0)

        // ファイルの置き場所を止め、置く処理を、応答に載っていると見たあとで待たせる。
        let disk = ActorHold()
        let diskTask = Task { await files.listed.hold(disk) }
        try await disk.entered.wait()
        defer { disk.release() }
        let writing = Task(priority: .background) {
            if prefetch {
                return try await files.storeListed(Data([2]), named: "emoji.png", for: url, remaining: 1)
            }
            return try await files.store(Data([2]), named: "emoji.png", for: url, generation: 0) == .listed
        }
        try await checkedCapacity.wait()

        // そのサーバーの最後のアカウントをログアウトして、応答を消したときと同じ分け直し。
        let removing = Task { await files.updateListed([]) }
        try await waitUntil { !files.isListed(url) }
        let owner = ActorHold()
        let ownerTask = Task { await files.hold(owner) }
        try await owner.entered.wait()
        defer { owner.release() }

        disk.release()
        try await waitUntil { await !files.listed.contains(url) }
        owner.release()
        await diskTask.value
        await ownerTask.value
        let kept = try await writing.value
        await removing.value

        #expect(kept == false)
        #expect(await files.containsListed(url) == false)
    }
}
