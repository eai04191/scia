import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
struct OversizedEmojiRecordTests {
    private let file = TestScratch.url("OversizedEmojiRecordTests").appending(path: "oversized.json")

    private func url(_ name: String) throws -> URL {
        try #require(URL(string: "https://files.example.social/custom_emojis/\(name)"))
    }

    /// 残した大きさは、起動し直しても引ける。
    @Test func keepsRecordAcrossInstances() throws {
        OversizedEmojiRecord(file: file).record(try url("big.gif"), width: 2_000, height: 2_000, frameCount: 10)

        let record = OversizedEmojiRecord(file: file)

        #expect(record.contains(try url("big.gif")))
        #expect(!record.contains(try url("other.gif")))
    }

    /// 版のない前の書き方のファイルは読まない。プリフェッチが別の絵文字の画像として置いたファイルから残した大きさを、持ち越さないため。
    @Test func ignoresRecordWithoutVersion() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"[{"url":"https://files.example.social/custom_emojis/big.gif","width":2000,"height":2000,"frameCount":10}]"#
        try Data(old.utf8).write(to: file)

        let record = OversizedEmojiRecord(file: file)

        #expect(!record.contains(try url("big.gif")))
        #expect(!record.wasKnownAtLaunch(try url("big.gif")))
    }

    /// 描く場所が動かない版を選ぶのは、起動したときに残っていたものだけ。この起動の間に残したものは、次の起動から選ぶ。
    @Test func choiceUsesOnlyRecordsKnownAtLaunch() throws {
        let emoji = CustomEmoji(shortcode: "big", url: try url("big.gif"), staticUrl: try url("big_static.png"))
        let record = OversizedEmojiRecord(file: file)

        record.record(emoji.url, width: 2_000, height: 2_000, frameCount: 10)

        #expect(EmojiImageChoice(animates: true, oversized: record).url(of: emoji) == emoji.url)
        #expect(EmojiImageChoice(animates: true, oversized: OversizedEmojiRecord(file: file)).url(of: emoji) == emoji.staticUrl)
    }

    /// 動かせるかは、残した大きさを引くたびに今の上限に当てて決める。上限に収まる大きさが残っていても、動かせないとは答えない。
    @Test func appliesCurrentLimitsToRecordedSize() throws {
        let record = OversizedEmojiRecord(file: file)

        record.record(try url("small.gif"), width: 100, height: 100, frameCount: 10)

        #expect(!record.contains(try url("small.gif")))
    }

    /// 上限の数を超えたら、古いものから消す。
    @Test func dropsOldestOverMaxCount() throws {
        let maxCount = 10
        let record = OversizedEmojiRecord(file: file, maxCount: maxCount)

        for index in 0...maxCount {
            record.record(try url("\(index).gif"), width: 2_000, height: 2_000, frameCount: 2)
        }

        #expect(!record.contains(try url("0.gif")))
        #expect(record.contains(try url("1.gif")))
        #expect(record.contains(try url("\(maxCount).gif")))
    }

    /// 動かす場所は元の画像、動かさない場所は動かない版を読む。
    @Test func choosesOriginalOnlyWhereAnimated() throws {
        let emoji = CustomEmoji(shortcode: "blob", url: try url("blob.gif"), staticUrl: try url("blob_static.png"))

        #expect(EmojiImageChoice(animates: true, oversized: nil).url(of: emoji) == emoji.url)
        #expect(EmojiImageChoice(animates: true, oversized: nil).animationURL(of: emoji) == emoji.url)
        #expect(EmojiImageChoice.still.url(of: emoji) == emoji.staticUrl)
        #expect(EmojiImageChoice.still.animationURL(of: emoji) == nil)
    }

    /// 届いた画像がこの絵文字のものかは、元の画像と動かない版の両方で見る。
    @Test func findsEitherImageAmongLoadedURLs() throws {
        let emoji = CustomEmoji(shortcode: "blob", url: try url("blob.gif"), staticUrl: try url("blob_static.png"))

        #expect(emoji.hasImage(in: [emoji.url]))
        #expect([emoji].hasImage(in: [emoji.staticUrl]))
        #expect(!emoji.hasImage(in: [try url("other.png")]))
    }

    /// 動かせない大きさは、コマの数、1コマの画素数、既定の高さで並べた画像の重さで決まる。1コマの画像は大きくても当てはまらない。
    @Test func oversizedLimits() {
        #expect(!AnimatedImage.exceedsEmojiLimits(frameCount: 40, width: 128, height: 128))
        #expect(AnimatedImage.exceedsEmojiLimits(frameCount: 2, width: 1_100, height: 1_000))
        #expect(AnimatedImage.exceedsEmojiLimits(frameCount: AnimatedImage.maxFrameCount + 1, width: 16, height: 16))
        #expect(AnimatedImage.exceedsEmojiLimits(frameCount: 400, width: 128, height: 128))
        #expect(!AnimatedImage.exceedsEmojiLimits(frameCount: 1, width: 4_000, height: 4_000))
    }
}
