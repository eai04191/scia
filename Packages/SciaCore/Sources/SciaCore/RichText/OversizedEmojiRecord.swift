public import Foundation
import os
import Synchronization

/// 大きすぎて動かせないと分かったカスタム絵文字の元の画像の、幅と高さとコマの数を、端末に残す。
/// 動かせるかは元の画像を読むまで分からないので、次に描くときに、読まずに動かない版を選ぶために使う（`EmojiImageChoice`）。
/// 残すのは大きさで、動かせるかの判断は残さない。引くたびに今の上限（`AnimatedImage.exceedsEmojiLimits`）に当てるので、上限を変えたら判断も変わる。
public final class OversizedEmojiRecord: Sendable {
    struct Entry: Codable, Equatable {
        let url: URL
        let width: Int
        let height: Int
        let frameCount: Int

        var isOversized: Bool {
            AnimatedImage.exceedsEmojiLimits(frameCount: frameCount, width: width, height: height)
        }
    }

    /// 残す数の上限。超えたら古いものから消す。消したものは、次に描くときに元の画像を読み直して、また残す。
    static let maxCount = 1_000

    public let file: URL
    private let entries: Mutex<[Entry]>
    /// 作ったとき（起動したとき）に残っていたもの。この起動の間に残したものは含めない。
    private let launchEntries: Mutex<[URL: Entry]>
    private let logger = SciaLog.logger(category: "emoji")

    public init(file: URL) {
        self.file = file
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
        entries = Mutex(stored ?? [])
        launchEntries = Mutex(Dictionary((stored ?? []).map { ($0.url, $0) }) { _, last in last })
    }

    /// `url`の元の画像は、今の上限では大きすぎて動かせないと分かっているか。この起動の間に残したものも含める。
    /// 元の画像のアニメーションを読まないことと、元の画像を端末に置かないことを決めるのに使う。
    public func contains(_ url: URL) -> Bool {
        entries.withLock { entries in entries.contains { $0.url == url && $0.isOversized } }
    }

    /// `url`の元の画像は、起動したときに、大きすぎて動かせないと分かっていたか。描く場所が、動かない版を読むと決めるのに使う（`EmojiImageChoice`）。
    /// この起動の間に分かったものは含めない。分かったときには元の画像の最初のコマで描けていて、そこで動かない版に切り替えると、読み終えるまで絵文字が消えるため。
    public func wasKnownAtLaunch(_ url: URL) -> Bool {
        launchEntries.withLock { $0[url]?.isOversized == true }
    }

    /// 大きさを残している元の画像のURL。設定のストレージで、記録をサーバーごとに数えるのに使う。
    public var recordedURLs: Set<URL> {
        entries.withLock { Set($0.map(\.url)) }
    }

    /// 大きすぎて動かせなかった元の画像の大きさを残す。
    public func record(_ url: URL, width: Int, height: Int, frameCount: Int) {
        let entry = Entry(url: url, width: width, height: height, frameCount: frameCount)
        let stored: [Entry]? = entries.withLock { entries in
            guard !entries.contains(entry) else { return nil }
            entries.removeAll { $0.url == url }
            entries.append(entry)
            entries.removeFirst(max(0, entries.count - Self.maxCount))
            return entries
        }
        if let stored {
            write(stored)
        }
    }

    private func write(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {
            logger.error("oversized emoji record write failed: \(SciaLog.describe(error), privacy: .public)")
        }
    }
}
