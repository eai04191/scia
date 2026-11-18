import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@Suite(.scratch)
struct EmojiImageFilesTests {
    private let root = TestScratch.url("EmojiImageFilesTests")

    /// 必須でない用途の空き容量。テストで手で決める。
    private final class Capacity: Sendable {
        let value = Mutex<Int?>(Int.max)
        let reads = Mutex(0)

        func read() -> Int? {
            reads.withLock { $0 += 1 }
            return value.withLock { $0 }
        }
    }

    private func makeFiles(capacity: Capacity = Capacity(), othersSizeLimit: Int = EmojiImageFiles.othersSizeLimit) -> EmojiImageFiles {
        EmojiImageFiles(directory: root.appending(path: "images"), sharingDirectory: root.appending(path: "sharing"), othersSizeLimit: othersSizeLimit) { capacity.read() }
    }

    private func url(_ name: String) throws -> URL {
        try #require(URL(string: "https://files.example.social/custom_emojis/\(name).png"))
    }

    private func image(_ size: Int = 16) -> Data {
        Data(repeating: 1, count: size)
    }

    /// 応答に載っている画像はAに、載っていない画像はBに置く。どちらも読める。
    @Test func placesListedImagesApartFromOthers() async throws {
        let files = makeFiles()
        await files.updateListed([try url("own")])

        let own = try await files.store(image(), named: "own.png", for: try url("own"), generation: 0)
        let other = try await files.store(image(), named: "other.png", for: try url("other"), generation: 0)

        #expect(own == .listed)
        #expect(other == .others)
        #expect(await files.data(for: try url("own")) != nil)
        #expect(await files.data(for: try url("other")) != nil)
        #expect(await files.containsListed(try url("other")) == false)
    }

    /// 今の版でないフォルダーに残ったAの画像は、応答に載っていても読まず、分け直しで消す。
    /// 先読みが別の絵文字の画像を置いたことがあり、残すと読み続けるため。版を付ける前のフォルダー（`Files`）も同じ。
    @Test(arguments: ["Files", "Listed/\(EmojiImageFiles.listedVersion - 1)"])
    func removesListedImagesOfOtherVersions(folder: String) async throws {
        let url = try url("a.png")
        let old = root.appending(path: "images/\(folder)")
        _ = try await MediaFileCache(directory: old, sharingDirectory: root.appending(path: "old-sharing"), sizeLimit: .max)
            .store(image(), named: "a.png", for: url, generation: 0)
        let files = makeFiles()

        await files.updateListed([url])

        #expect(await files.data(for: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    }

    /// 今の版のフォルダーに置いたAの画像は、分け直しても残る。
    @Test func keepsListedImagesOfCurrentVersion() async throws {
        let url = try url("a.png")
        let files = makeFiles()
        await files.updateListed([url])
        try await files.store(image(), named: "a.png", for: url, generation: files.generation)

        await makeFiles().updateListed([url])

        #expect(await makeFiles().data(for: url) == image())
    }

    /// 応答を読むまでは、どれもBに置き、読んだら、載っていた画像をAへ移す。
    @Test func movesOthersToListedWhenTheyAppearInResponse() async throws {
        let files = makeFiles()
        _ = try await files.store(image(), named: "own.png", for: try url("own"), generation: 0)
        #expect(await files.containsListed(try url("own")) == false)

        await files.updateListed([try url("own")])

        #expect(await files.containsListed(try url("own")))
        #expect(await files.others.contains(try url("own")) == false)
        #expect(await files.data(for: try url("own")) == image())
    }

    /// 応答から外れたAの画像は消す。管理者が絵文字を消したときと、画像を差し替えてURLが変わったとき。
    @Test func removesListedImagesThatLeftResponse() async throws {
        let files = makeFiles()
        await files.updateListed([try url("kept"), try url("replaced")])
        _ = try await files.store(image(), named: "kept.png", for: try url("kept"), generation: 0)
        _ = try await files.store(image(), named: "replaced.png", for: try url("replaced"), generation: 0)

        await files.updateListed([try url("kept"), try url("replacement")])

        #expect(await files.containsListed(try url("kept")))
        #expect(await files.data(for: try url("replaced")) == nil)
    }

    /// Bが上限を超えたら、Bだけを消す。Aは、上限を超えても消さない。
    @Test func trimsOnlyOthers() async throws {
        let files = makeFiles(othersSizeLimit: 40 * 1_024)
        let listed = try (0..<8).map { try url("own\($0)") }
        await files.updateListed(Set(listed))
        for url in listed {
            _ = try await files.store(image(16 * 1_024), named: url.lastPathComponent, for: url, generation: 0)
        }

        for index in 0..<6 {
            _ = try await files.store(image(16 * 1_024), named: "other\(index).png", for: try url("other\(index)"), generation: 0)
        }

        for url in listed {
            #expect(await files.containsListed(url))
        }
        let others = await files.others.summary()
        #expect(others.count < 6)
        #expect(others.size <= 40 * 1_024)
        #expect(await files.others.trimCount > 0)
    }

    /// 必須でない用途の空きが足りなければ、描くために取得した応答の画像も、Bに置く。
    @Test func placesListedImageInOthersWithoutRoom() async throws {
        let capacity = Capacity()
        capacity.value.withLock { $0 = 8 }
        let files = makeFiles(capacity: capacity)
        await files.updateListed([try url("own")])

        let placement = try await files.store(image(), named: "own.png", for: try url("own"), generation: 0)

        #expect(placement == .others)
        #expect(await files.data(for: try url("own")) != nil)
    }

    /// 空きが足りずにBに置いた応答の画像は、分け直しても、空きが足りなければBに残す。Aへ移すと、上限と「キャッシュを消去」から外れるため。
    @Test func keepsOthersWhenRoomIsShortOnUpdate() async throws {
        let capacity = Capacity()
        capacity.value.withLock { $0 = 8 }
        let files = makeFiles(capacity: capacity)
        await files.updateListed([try url("own")])
        _ = try await files.store(image(), named: "own.png", for: try url("own"), generation: 0)

        await files.updateListed([try url("own")])

        #expect(await files.containsListed(try url("own")) == false)
        #expect(await files.others.contains(try url("own")))
    }

    /// 分け直しの途中で、ログアウトして応答を消した分け直しが割り込んでも、古い分け直しが画像をAへ戻さない。
    /// 戻すと、応答に載っていない画像が、上限にも「キャッシュを消去」にもかからないAに残るため。
    @Test func laterUpdateWinsOverInterruptedUpdate() async throws {
        let files = makeFiles()
        let urls = try (0..<300).map { try url("own\($0)") }
        for url in urls {
            _ = try await files.store(image(), named: url.lastPathComponent, for: url, generation: 0)
        }
        let older = Task { await files.updateListed(Set(urls)) }
        try await waitUntil { await files.listed.summary().count >= 1 }

        await files.updateListed([])
        await older.value

        #expect(await files.listed.summary().count == 0)
    }

    /// 応答に載っているかは、順番を待たずに引ける。応答を読むまではどれも載っていない。
    @Test func answersWhetherListedWithoutWaiting() async throws {
        let files = makeFiles()
        #expect(files.isListed(try url("own")) == false)

        await files.updateListed([try url("own")])

        #expect(files.isListed(try url("own")))
        #expect(files.isListed(try url("other")) == false)
    }

    /// 先読みの画像は、空きが残りの取得量の見積もりに足りなければ、置かない。Bにも置かない。
    @Test func storeListedRefusesWhenRemainingDoesNotFit() async throws {
        let capacity = Capacity()
        capacity.value.withLock { $0 = 1_000 }
        let files = makeFiles(capacity: capacity)
        await files.updateListed([try url("a"), try url("b")])

        #expect(try await files.storeListed(image(), named: "a.png", for: try url("a"), remaining: 900))
        #expect(try await files.storeListed(image(), named: "b.png", for: try url("b"), remaining: 2_000) == false)

        #expect(await files.data(for: try url("b")) == nil)
    }

    /// 空き容量は、画像1枚ごとには読まず、置いた量が10MBに届くたびに読み直す。値を1回読むのに、SE3で約9msかかるため。
    @Test func rereadsCapacityEveryTenMegabytes() async throws {
        let capacity = Capacity()
        let files = makeFiles(capacity: capacity)
        let urls = try (0..<6).map { try url("own\($0)") }
        await files.updateListed(Set(urls))

        for url in urls {
            _ = try await files.store(image(4 * 1_024 * 1_024), named: url.lastPathComponent, for: url, generation: 0)
        }

        // 1枚目を置く前と、3枚で12MB置いたあとの4枚目を置く前。
        #expect(capacity.reads.withLock { $0 } == 2)
    }

    /// 「キャッシュを消去」はBだけを消す。Aは残す。
    @Test func removeOthersKeepsListed() async throws {
        let files = makeFiles()
        await files.updateListed([try url("own")])
        _ = try await files.store(image(), named: "own.png", for: try url("own"), generation: 0)
        _ = try await files.store(image(), named: "other.png", for: try url("other"), generation: 0)

        try await files.removeOthers()

        #expect(await files.containsListed(try url("own")))
        #expect(await files.data(for: try url("other")) == nil)
        await #expect(throws: CancellationError.self) {
            try await files.store(image(), named: "late.png", for: try url("late"), generation: 0)
        }
    }

    /// 状態ダンプに、Bの数と合計、上限を超えて消した回数を出す。
    @Test func stateDumpShowsOthers() async throws {
        let files = makeFiles()
        _ = try await files.store(image(), named: "other.png", for: try url("other"), generation: 0)

        await files.refreshStats()

        #expect(files.stateDump().contains("others: count=1"))
        #expect(files.stateDump().contains("trims=0"))
    }
}
