public import Foundation
import os

/// サーバーのカスタム絵文字のリストを、サーバーごとに端末に残す。決まりはdocs/compose.mdの「並べ方」にある。
/// 絵文字のパレットを開いたときに、読み込み中を挟まずに前に読んだリストで並べるため。
/// リストには絵文字ごとの縦横比も持たせる。Mastodonは画像の幅と高さを返さないので、画像が届いたときに分かった縦横比を残し、次に開いたときから横長の絵文字にマスを足す。
/// サーバーのリストは、ログインしている同じサーバーのアカウントとウィンドウのあいだで同じなので、アプリ全体で1つの`CustomEmojiCaches`が、サーバーごとに1つ持つ。
@MainActor
public final class CustomEmojiCache {
    /// 補完とパレットに渡す、残しているリスト。
    public struct Snapshot: Sendable, Equatable {
        /// 残しているリスト。端末にもなく、まだ読めていなければnil。
        public let emojis: [ServerEmoji]?
        /// この起動のうちにサーバーから読んだリストか。falseなら端末に残したリストで、読み直す。
        public let isFresh: Bool
        /// サーバーが縦横比を返さない絵文字の、画像から分かった縦横比（幅/高さ）。静止画のURLで引く。
        public let learnedAspectRatios: [URL: Double]
        /// リストを消した回数。補完は、持っているリストを受け取ったときと違えば、そのリストも捨てて読み直す。
        public let generation: Int
    }

    /// 縦横比が分かってから端末に書き出すまでの間。タイムラインをスクロールする間に次々届く画像の分を、まとめて書き出すため。
    static let saveDelay: Duration = .seconds(2)

    private let server: String
    private let files: CustomEmojiFiles
    private let clock: any Clock<Duration>
    private let logger = SciaLog.logger(category: "emoji")
    private(set) var emojis: [ServerEmoji]?
    private var isFresh = false
    private var learnedAspectRatios: [URL: Double] = [:]
    /// サーバーが縦横比を返さない絵文字の、アニメーション版と静止画のURLから、静止画のURLを引く。どちらの画像が届いても縦横比を残すため。
    private var staticURLs: [URL: URL] = [:]
    /// リストがまだないときに届いた画像の縦横比。リストが届いたら、リストにある絵文字の分を残す。
    /// リストより先に投稿の本文で読んだ画像は、メモリに残っている間は読み直さず、大きさをもう一度知る機会がないため。
    /// ほかのサーバーの絵文字も入るので、`pendingLimit`を超えたら捨てる。
    private var pendingAspectRatios: [URL: Double] = [:]
    static let pendingLimit = 1_000
    private var saveTask: Task<Void, Never>?
    /// 端末に残したリストを読んでいる途中の処理。テストで、読み終えるのを待つ。
    private(set) var restoreTask: Task<Void, Never>?
    /// `remove()`で消すたびに進める。消す前に読み始めた端末のリストや通信の応答と、消す前に予約した書き出しで、消したあとのリストを埋めないため。
    private(set) var generation = 0

    init(server: String, files: CustomEmojiFiles, clock: any Clock<Duration>) {
        self.server = server
        self.files = files
        self.clock = clock
        restore()
    }

    public var snapshot: Snapshot {
        Snapshot(emojis: emojis, isFresh: isFresh, learnedAspectRatios: learnedAspectRatios, generation: generation)
    }

    /// サーバーから読めたリストを残す。前に分かった縦横比は、静止画のURLが同じ絵文字だけ引き継ぐ。
    /// リストから消えた絵文字の分と、画像を差し替えてURLが変わった絵文字の分は捨てる。
    /// - Parameter generation: 読み始めたときの`generation`。その後に消していたら残さない。消したあとに、そのサーバーのアカウントがないのにリストを作り直さないため。
    func remember(_ emojis: [ServerEmoji], loadStartedAt generation: Int) {
        guard generation == self.generation else { return }
        let staticURLs = Set(emojis.map(\.staticUrl))
        learnedAspectRatios = learnedAspectRatios.filter { staticURLs.contains($0.key) }
        set(emojis)
        _ = adoptPendingAspectRatios()
        isFresh = true
        restoreTask?.cancel()
        restoreTask = nil
        save()
    }

    /// 画像が届いたときに、元の画像の幅と高さを渡す。リストにあり、サーバーが縦横比を返していない絵文字なら、縦横比を残す。
    func learn(_ url: URL, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let aspectRatio = Double(width) / Double(height)
        guard emojis != nil else {
            if pendingAspectRatios.count >= Self.pendingLimit {
                pendingAspectRatios = [:]
            }
            pendingAspectRatios[url] = aspectRatio
            return
        }
        guard let staticURL = staticURLs[url] else { return }
        guard learnedAspectRatios[staticURL] != aspectRatio else { return }
        learnedAspectRatios[staticURL] = aspectRatio
        scheduleSave()
    }

    /// 残しているリストを、メモリからも端末からも消す。
    func remove() async {
        generation += 1
        emojis = nil
        isFresh = false
        learnedAspectRatios = [:]
        pendingAspectRatios = [:]
        staticURLs = [:]
        restoreTask?.cancel()
        restoreTask = nil
        saveTask?.cancel()
        saveTask = nil
        await files.remove(server: server)
    }

    private func set(_ emojis: [ServerEmoji]) {
        self.emojis = emojis
        var staticURLs: [URL: URL] = [:]
        for emoji in emojis where emoji.aspectRatio == nil {
            staticURLs[emoji.url] = emoji.staticUrl
            staticURLs[emoji.staticUrl] = emoji.staticUrl
        }
        self.staticURLs = staticURLs
    }

    /// リストがないときに届いた画像の縦横比のうち、リストにある絵文字の分を残す。残したらtrue。
    private func adoptPendingAspectRatios() -> Bool {
        defer { pendingAspectRatios = [:] }
        var adopted = false
        for (url, aspectRatio) in pendingAspectRatios {
            guard let staticURL = staticURLs[url], learnedAspectRatios[staticURL] == nil else { continue }
            learnedAspectRatios[staticURL] = aspectRatio
            adopted = true
        }
        return adopted
    }

    /// 端末に残したリストを読む。読み終える前にサーバーから読めていれば、そちらを使う。
    private func restore() {
        let generation = generation
        restoreTask = Task { [weak self, files, server] in
            let stored = await files.read(server: server)
            guard let self, generation == self.generation, emojis == nil, let stored else { return }
            var learned: [URL: Double] = [:]
            for entry in stored.emojis {
                learned[entry.staticUrl] = entry.aspectRatio
            }
            set(stored.emojis.map(\.emoji))
            learnedAspectRatios = learned
            if adoptPendingAspectRatios() {
                scheduleSave()
            }
            restoreTask = nil
            logger.info("custom emojis restored: \(stored.emojis.count, privacy: .public) (aspect ratios: \(learned.count, privacy: .public))")
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let clock = clock
        saveTask = Task { [weak self] in
            try? await clock.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            save()
        }
    }

    /// リストと分かっている縦横比を書き出す。端末から読んだリストのままでも書く。読み直す前にタイムラインで分かった縦横比を、次の起動に残すため。
    private func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let emojis else { return }
        let stored = StoredCustomEmojis(emojis: emojis.map { emoji in
            StoredCustomEmojis.Entry(emoji, aspectRatio: emoji.aspectRatio ?? learnedAspectRatios[emoji.staticUrl])
        })
        let files = files
        let server = server
        let generation = generation
        // 始める前に消していたら書かない。消す処理より先にファイルへ届いた書き出しは、消す処理が後から消す。
        Task { [weak self] in
            guard self?.generation == generation else { return }
            await files.write(stored, server: server)
        }
    }
}

/// アプリ全体で、サーバーごとの`CustomEmojiCache`を持つ。
@MainActor
public final class CustomEmojiCaches {
    private let files: CustomEmojiFiles
    private let clock: any Clock<Duration>
    private var caches: [String: CustomEmojiCache] = [:]

    /// - Parameter directory: リストを書き出すフォルダー。サーバーの応答から作れるので、OSが空き容量に応じて消してよい`Caches`に置く。
    public init(directory: URL = .cachesDirectory.appending(path: "CustomEmojis"), clock: any Clock<Duration> = SystemTime.clock) {
        files = CustomEmojiFiles(directory: directory)
        self.clock = clock
    }

    /// リストを書き出すフォルダー。設定のストレージで測る。
    public nonisolated var directory: URL { files.directory }

    /// `instance`のサーバーのリスト。初めて求めたときに作り、端末に残したリストを読み始める。
    public func cache(for instance: URL) -> CustomEmojiCache {
        let server = Self.server(of: instance)
        if let cache = caches[server] {
            return cache
        }
        let cache = CustomEmojiCache(server: server, files: files, clock: clock)
        caches[server] = cache
        return cache
    }

    /// 画像が届いたときに、元の画像の幅と高さを渡す。その絵文字があるリストに、縦横比を残す。
    public func learn(_ url: URL, width: Int, height: Int) {
        for cache in caches.values {
            cache.learn(url, width: width, height: height)
        }
    }

    /// `instance`のサーバーのリストを消す。そのサーバーのアカウントを全部ログアウトしたときに呼ぶ。
    public func remove(instance: URL) async {
        let server = Self.server(of: instance)
        if let cache = caches.removeValue(forKey: server) {
            await cache.remove()
        } else {
            await files.remove(server: server)
        }
    }

    /// すべてのサーバーのリストを消す。設定のストレージで、通信のキャッシュと一緒に消す。
    /// 開いている画面のリストを、次に書き出すときに戻さないよう、メモリに持っているリストも消す。
    public func removeAll() async {
        for cache in caches.values {
            await cache.remove()
        }
        await files.removeAll()
    }

    /// サーバーを見分ける名前。サーバーのための設定の値（`AccountScopedDefaults.key(_:server:)`）と同じく、ホスト名で見分ける。
    private static func server(of instance: URL) -> String {
        instance.host()?.lowercased() ?? instance.absoluteString
    }
}

/// 端末に書き出すリスト。
struct StoredCustomEmojis: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let shortcode: String
        let url: URL
        let staticUrl: URL
        let visibleInPicker: Bool
        let category: String?
        /// サーバーが返した縦横比か、画像から分かった縦横比。どちらも分からなければnil。
        let aspectRatio: Double?

        init(_ emoji: ServerEmoji, aspectRatio: Double?) {
            shortcode = emoji.shortcode
            url = emoji.url
            staticUrl = emoji.staticUrl
            visibleInPicker = emoji.visibleInPicker
            category = emoji.category
            self.aspectRatio = aspectRatio
        }

        private enum CodingKeys: String, CodingKey {
            case shortcode, url, staticUrl, visibleInPicker, category, aspectRatio
        }

        /// URLは、サーバーの応答を読むときと同じく、読み込む画像として受け付けるスキームだけを通す。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shortcode = try container.decode(String.self, forKey: .shortcode)
            url = try container.decodeRequiredURL(.media, forKey: .url)
            staticUrl = try container.decodeRequiredURL(.media, forKey: .staticUrl)
            visibleInPicker = try container.decode(Bool.self, forKey: .visibleInPicker)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            aspectRatio = try container.decodeIfPresent(Double.self, forKey: .aspectRatio).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }

        /// 縦横比は、サーバーが返したものと見分けずに、画像から分かったものとして持つ。読み直したリストでサーバーが返せば、そちらを使う。
        var emoji: ServerEmoji {
            ServerEmoji(shortcode: shortcode, url: url, staticUrl: staticUrl, visibleInPicker: visibleInPicker, category: category)
        }
    }

    /// 書き方を変えたら上げる。読んだファイルの値が違えば、読まずにサーバーから読み直す。
    static let currentVersion = 1

    let version: Int
    let emojis: [Entry]

    init(emojis: [Entry]) {
        version = Self.currentVersion
        self.emojis = emojis
    }
}

/// リストのファイルを読み書きする。書いている途中に消したり読んだりしないよう、actorで1つずつ行う。
actor CustomEmojiFiles {
    nonisolated let directory: URL
    private let logger = SciaLog.logger(category: "emoji")

    init(directory: URL) {
        self.directory = directory
    }

    private func file(server: String) -> URL {
        directory.appending(fileName: SafeFileName("\(server).json"))
    }

    /// 読めないか、書き方の違うファイルはnil。サーバーから読み直せば書き直す。
    func read(server: String) -> StoredCustomEmojis? {
        let file = file(server: server)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let stored = try JSONDecoder().decode(StoredCustomEmojis.self, from: data)
            return stored.version == StoredCustomEmojis.currentVersion ? stored : nil
        } catch {
            logger.error("custom emojis file unreadable: \(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    /// 書いている途中で落ちても、書きかけのファイルを読まないよう、別のファイルに書いてから置き換える。
    func write(_ stored: StoredCustomEmojis, server: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: file(server: server), options: .atomic)
        } catch {
            logger.error("custom emojis file write failed: \(SciaLog.describe(error), privacy: .public)")
        }
    }

    func remove(server: String) {
        try? FileManager.default.removeItem(at: file(server: server))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension ComposeCompletion.Sources {
    /// カスタム絵文字のリストを読めたら、`cache`に残させ、補完が作られたときと読み直す前に、残したリストを渡させる。
    /// 読めなかったときは、前に読めたリストを残す。
    public func remembering(customEmojisIn cache: CustomEmojiCache) -> Self {
        var sources = self
        let load = customEmojis
        sources.customEmojis = {
            let generation = await cache.generation
            let emojis = try await load()
            await cache.remember(emojis, loadStartedAt: generation)
            return emojis
        }
        sources.cachedCustomEmojis = { [weak cache] in cache?.snapshot }
        return sources
    }
}
