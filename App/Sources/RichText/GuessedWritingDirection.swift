import NaturalLanguage
import SciaCore
import Synchronization

/// 文字の言語から推し量った、書く方向。言語の分からない文字（リンク先のページのタイトルなど）を、その言語の書く方向に寄せるのに使う。
/// 言語の判定は、呼ぶたびに判定のモデルを作り直すため重く、一覧の行を組み立てるたびに呼ぶとフレームが落ちた。
/// 結果を覚えておき、一覧では画面に入る前にメインスレッドの外で判定しておく（`BodyTextPreparer`）。
enum GuessedWritingDirection {
    /// 判定した結果。キーの文字列の長さ（UTF-16の数）を重さにして上限を付け、投稿から読んだ文字列を持ち続けないようにする。
    private static let cache = Mutex(CostLimitedCache<String, Bool>(totalCostLimit: 256 * 1024))

    /// 判定に使う、文字の先頭の長さ（文字の数）。言語は先頭で分かり、長い説明の全体で判定すると時間がかかるうえ、覚えておく表に入りきらない。
    private static let sampleLength = 256

    /// `string`をもう判定してあるか。
    static func isKnown(_ string: String) -> Bool {
        let sample = String(string.prefix(sampleLength))
        return cache.withLock { $0.value(forKey: sample) } != nil
    }

    /// `string`の言語が右から左に書く言語か。判定できなければfalse。
    static func isRightToLeft(_ string: String) -> Bool {
        let sample = String(string.prefix(sampleLength))
        if let cached = cache.withLock({ $0.value(forKey: sample) }) { return cached }
        let result = NLLanguageRecognizer.dominantLanguage(for: sample).map {
            Locale.Language(identifier: $0.rawValue).characterDirection == .rightToLeft
        } ?? false
        _ = cache.withLock { $0.setValue(result, forKey: sample, cost: max(sample.utf16.count, 1)) }
        return result
    }
}
