#if DEBUG
import Foundation
import SciaCore
import Synchronization

/// シミュレーターでは翻訳の言語が使えないため、`scia-debug://translation/fake`で、通信もモデルも使わないダミーの訳文に替える。
/// 訳文は本文を2回つないだ文字にし、置き換えで高さが変わるところを確かめられるようにする。
struct DebugStatusTranslator: StatusTranslating {
    /// ダミーの訳文を返すまでの時間。nilならOSの翻訳を使う。
    private static let fakeDelay = Mutex<Duration?>(nil)

    static var isFake: Bool {
        fakeDelay.withLock { $0 != nil }
    }

    static func setFakeDelay(_ delay: Duration?) {
        fakeDelay.withLock { $0 = delay }
    }

    let system: (any StatusTranslating)?

    func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart] {
        if let delay = Self.fakeDelay.withLock({ $0 }) {
            try await Task.sleep(for: delay)
            return parts.map { part in
                if case .text(let text) = part, text.contains(where: \.isLetter) { .text("（\(target)・\(strategy.rawValue)の訳文）\(text)\(text)") } else { part }
            }
        }
        guard let system else { throw StatusTranslationError.notInstalled }
        return try await system.translate(parts, from: source, to: target, strategy: strategy)
    }
}
#endif
