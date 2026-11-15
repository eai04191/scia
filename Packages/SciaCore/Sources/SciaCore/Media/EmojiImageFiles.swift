public import Foundation
import os
import Synchronization

/// カスタム絵文字の画像を、端末に残した`api/v1/custom_emojis`の応答に載っているか（A）、いないか（B）で分けて置く
/// （docs/animated-custom-emoji.mdの「端末に置く画像の分け方」）。
///
/// Aは、絵文字ピッカーを空白なく出すために持っておく画像で、数はサーバーの絵文字の数で決まるので、上限で消さない。
/// 応答から外れたときと、必須でない用途の空き容量が足りないときだけ持たない。
/// Bは、タイムラインでほかのサーバーの人の絵文字を見るほど増えるので、`othersSizeLimit`の上限をかけ、最後に使ったのが古いものから消す。
/// 同じ上限を分け合うと、ほかのサーバーの絵文字を見るほど、Aが押し出されて消え、絵文字ピッカーで取得し直していたため。
public actor EmojiImageFiles {
    /// Bの上限。fedibird.comの絵文字の元の画像は、150個の抜き取りで平均約20KBで、同じくらいなら約3,300個、消し始めたあとも約2,300個が残る。
    /// ふだんの使い方でどれだけ入るかは測っていないので、状態ダンプの数を見て、あふれが多ければ上げる。
    public static let othersSizeLimit = 64 * 1_024 * 1_024
    /// 必須でない用途の空き容量を読み直すまでに、Aに置く量。値を1回読むのに、SE3で約9msかかるため、画像1枚ごとには読まない。
    static let capacityCheckInterval = 10 * 1_024 * 1_024

    /// どこに置いたか。
    public enum Placement: Equatable, Sendable {
        case listed
        case others
    }

    nonisolated let listed: MediaFileCache
    nonisolated let others: MediaFileCache
    private let availableCapacity: @Sendable () -> Int?
    private let logger = SciaLog.logger(category: "emoji")
    /// 端末に残した`api/v1/custom_emojis`の応答に載っている画像のURL。読むまではnilで、その間はどれもBに置く。
    /// 載っていたURLの画像は、読んだときに`updateListed(_:)`がAへ移す。
    private var listedURLs: Set<URL>? {
        didSet {
            let urls = listedURLs
            listedSnapshot.withLock { $0 = urls }
        }
    }
    /// `listedURLs`を、順番を待たずに読むためのもの。
    private let listedSnapshot = Mutex<Set<URL>?>(nil)
    /// 最後に読んだ、必須でない用途の空き容量と、そのあとAに置いた量。
    private var capacity: (available: Int, placedSince: Int)?
    /// `updateListed(_:)`を始めるたびに進める。
    private var listingGeneration = 0
    /// Bを消すたびに進める。置く側は読み始めたときの値を`store`に渡し、その間に消していたら置かない。
    public private(set) var generation = 0
    private let stats = Mutex(Stats())

    /// - Parameters:
    ///   - directory: AとBのフォルダーを置くフォルダー。
    ///   - availableCapacity: 必須でない用途の空き容量（バイト）。読めなければnilで、足りないものとして扱う。テストでは差し替える。
    public init(
        directory: URL,
        sharingDirectory: URL,
        othersSizeLimit: Int = EmojiImageFiles.othersSizeLimit,
        availableCapacity: @escaping @Sendable () -> Int? = EmojiImageFiles.opportunisticCapacity
    ) {
        // Aは、前の作りがすべての画像を置いていたフォルダー（`Files`）をそのまま使う。起動したときの分け直し（`updateListed(_:)`）で、
        // 応答に載っていない画像が消えるので、前の作りで置いたほかのサーバーの絵文字の画像が、「キャッシュを消去」で消せないまま残らない。
        listed = MediaFileCache(directory: directory.appending(path: "Files"), sharingDirectory: sharingDirectory.appending(path: "Listed"), sizeLimit: .max)
        others = MediaFileCache(directory: directory.appending(path: "Others"), sharingDirectory: sharingDirectory.appending(path: "Others"), sizeLimit: othersSizeLimit)
        self.availableCapacity = availableCapacity
    }

    /// 必須でない用途の空き容量（`volumeAvailableCapacityForOpportunisticUsageKey`）。先を見越して取得するものは、これで確かめてから置く（Appleの「Checking Volume Storage Capacity」）。
    public static let opportunisticCapacity: @Sendable () -> Int? = {
        let values = try? URL.cachesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey])
        return values?.volumeAvailableCapacityForOpportunisticUsage.map { Int(clamping: $0) }
    }

    /// `url`の画像が、AかBに置いてあれば、その中身。ほかの操作の順番を待たずに、並べて読む。
    @concurrent
    public nonisolated func data(for url: URL, touching: Bool = true) async -> Data? {
        if let data = await listed.data(for: url, touching: touching) {
            return data
        }
        return await others.data(for: url, touching: touching)
    }

    /// `url`が、端末に残したどれかのサーバーの`api/v1/custom_emojis`の応答に載っているか。応答を読むまではfalse。
    /// 絵文字ピッカーの小さい静止画を、絵文字ピッカーに出る絵文字だけに足すのに使う。
    public nonisolated func isListed(_ url: URL) -> Bool {
        listedSnapshot.withLock { $0?.contains(url) == true }
    }

    /// `url`の画像が、Aに置いてあるか。
    public func containsListed(_ url: URL) async -> Bool {
        await listed.contains(url)
    }

    /// 描くために取得した画像を置く。応答に載っていて、必須でない用途の空きがこの画像の分あればA、ほかはBに置く。
    /// 空き容量が足りないときに描くために取得したAの画像は、Bとして扱う（上限で入れ替わる）。
    @discardableResult
    public func store(_ data: Data, named name: String, for url: URL, generation: Int) async throws -> Placement {
        guard generation == self.generation else { throw CancellationError() }
        if listedURLs?.contains(url) == true, hasRoom(for: data.count) {
            _ = try await listed.store(data, named: name, for: url, generation: listed.generation)
            // 置くのを待つ間に、分け直しで応答から外れていたら（ログアウトなど）、Aに残さずBとして置く。
            // Aに残すと、次の分け直しまで、上限にも「キャッシュを消去」にもかからないため。
            if listedURLs?.contains(url) == true {
                await others.remove(url)
                placed(data.count)
                return .listed
            }
            await listed.remove(url)
        }
        _ = try await others.store(data, named: name, for: url, generation: others.generation)
        othersStores += 1
        if othersStores % Self.statsRefreshInterval == 0 {
            await refreshStats()
        }
        return .others
    }

    /// Bに置いた数。状態ダンプの数を、置き場所を調べ直してまで、置くたびに読み直さないため。
    private var othersStores = 0
    /// 状態ダンプの数を読み直すまでに、Bに置く数。
    static let statsRefreshInterval = 100

    /// 先読みで取得した画像を、Aに置く。応答に載っていないか、必須でない用途の空きが`remaining`（これから取得する量の見積もり）に足りなければ、置かずにfalse。
    public func storeListed(_ data: Data, named name: String, for url: URL, remaining: Int) async throws -> Bool {
        guard listedURLs?.contains(url) == true, hasRoom(for: max(remaining, data.count)) else { return false }
        _ = try await listed.store(data, named: name, for: url, generation: listed.generation)
        // 置くのを待つ間に、分け直しで応答から外れていたら、Aに残さない。
        guard listedURLs?.contains(url) == true else {
            await listed.remove(url)
            return false
        }
        await others.remove(url)
        placed(data.count)
        return true
    }

    /// 必須でない用途の空きが、`bytes`以上あるか。読んでいないか、前に読んでから`capacityCheckInterval`以上置いていれば、読み直す。
    /// 先読みは取得を始める前に呼び、読み直させる。
    public func hasRoom(for bytes: Int, rereading: Bool = false) -> Bool {
        if rereading || capacity.map({ $0.placedSince >= Self.capacityCheckInterval }) ?? true {
            capacity = (availableCapacity() ?? 0, 0)
            stats.withLock { $0.capacityReads += 1 }
        }
        guard let capacity else { return false }
        return capacity.available - capacity.placedSince >= bytes
    }

    private func placed(_ bytes: Int) {
        capacity?.placedSince += bytes
    }

    /// 端末に残した`api/v1/custom_emojis`の応答に載っている画像のURLを渡す。応答を読んだとき、ログアウトして応答を消したとき、起動したときに呼ぶ。
    /// 載らなくなったAの画像は消し、載ったBの画像はAへ移す（中身は読まずにファイルを移す）。
    public func updateListed(_ urls: Set<URL>) async {
        // ファイルを移すのを待つ間に、次の分け直しが割り込むことがある。古い分け直しは途中でやめ、
        // 移し終えた画像が新しい応答に載っていなければ消す。新しい分け直しが消した画像を、Aへ戻さないため。
        listingGeneration += 1
        let generation = listingGeneration
        listedURLs = urls
        let removed = await listed.remove(except: urls)
        let othersSizes = await others.sizesByFolderName()
        var moved = 0
        for url in urls {
            guard generation == listingGeneration else { break }
            // 空きが足りないときに描くために取得した画像は、Bとして置いたままにする。移すと、上限と「キャッシュを消去」から外れるため。
            guard let size = othersSizes[MediaFileCache.folderName(for: url)], hasRoom(for: size) else { continue }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "EmojiImageMove-\(UUID().uuidString)")
            do {
                guard let name = try await others.take(url, to: temporary) else { continue }
                _ = try await listed.store(movingFile: temporary, named: name, for: url, generation: listed.generation)
                guard listedURLs?.contains(url) == true else {
                    await listed.remove(url)
                    continue
                }
                placed(size)
                moved += 1
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                logger.error("emoji image move failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
        logger.info("emoji images listed=\(urls.count, privacy: .public) removed=\(removed, privacy: .public) moved=\(moved, privacy: .public)")
    }

    /// AとBに置いた画像の大きさを、フォルダーの名前（`MediaFileCache.folderName(for:)`）で引けるように並べる。設定のストレージで、サーバーごとに数えるのに使う。
    public func sizesByFolderName() async -> (listed: [String: Int], others: [String: Int]) {
        (await listed.sizesByFolderName(), await others.sizesByFolderName())
    }

    /// Bのフォルダー。設定のストレージで、「キャッシュを消去」で消える大きさを測る。
    public nonisolated var othersDirectory: URL { others.directory }

    /// 置いた画像を、AとBの両方から消す。画像として読めなかったときに呼ぶ。
    public func remove(_ url: URL) async {
        await listed.remove(url)
        await others.remove(url)
    }

    /// Bを全部消す。設定のストレージの「キャッシュを消去」で呼ぶ。Aは、絵文字ピッカーを空白なく出すのに要り、次に応答を読めば先読みでまた取得するので、消さない。
    public func removeOthers() async throws {
        generation += 1
        try await others.removeCachedFiles()
    }

    /// 状態ダンプに出す数を読み直す。
    public func refreshStats() async {
        let summary = await others.summary()
        let trims = await others.trimCount
        let listedCount = listedURLs?.count
        stats.withLock {
            $0.othersCount = summary.count
            $0.othersSize = summary.size
            $0.othersTrims = trims
            $0.listedURLs = listedCount
        }
    }

    /// 状態ダンプ。Bの数と合計、上限を超えて消した回数を出す。ふだん使いで`othersSizeLimit`が足りているかを確かめるため。
    /// 数は`refreshStats()`で読んだときのもの。
    public nonisolated func stateDump() -> String {
        let stats = stats.withLock { $0 }
        return """
        others: count=\(stats.othersCount) size=\(stats.othersSize) limit=\(others.sizeLimit) trims=\(stats.othersTrims)
        listedURLs: \(stats.listedURLs.map(String.init) ?? "unknown") capacityReads=\(stats.capacityReads)
        """
    }

    private struct Stats {
        var othersCount = 0
        var othersSize = 0
        var othersTrims = 0
        var listedURLs: Int?
        var capacityReads = 0
    }
}
