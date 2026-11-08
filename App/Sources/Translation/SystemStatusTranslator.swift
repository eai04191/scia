import Foundation
import SciaCore
import Translation

/// OSのTranslationフレームワークで段落を訳す。ダウンロードは求めず、言語モデルがなければ`notInstalled`を投げる（docs/auto-translation.md）。
@available(iOS 26.4, *)
struct SystemStatusTranslator: StatusTranslating {
    /// 残す部分に付けるリンクのスキーム。訳文の中で、どの部分が元のどれかを見分ける。
    private static let partScheme = "scia-translation-part"

    func translate(_ parts: [TranslationPart], from source: String, to target: String) async throws -> [TranslationPart] {
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        do {
            guard let output = try await session.translate(Self.attributedString(from: parts)).attributedTargetText else {
                throw StatusTranslationError.preservedPartsChanged
            }
            return Self.parts(from: output)
        } catch let error where TranslationError.notInstalled ~= error {
            throw StatusTranslationError.notInstalled
        }
    }

    static func attributedString(from parts: [TranslationPart]) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            switch part {
            case .text(let text):
                result += AttributedString(text)
            case .preserved(let text, let id):
                var piece = AttributedString(text)
                piece.link = URL(string: "\(partScheme):\(id)")
                piece.translation.skipsTranslation = true
                result += piece
            }
        }
    }

    static func parts(from output: AttributedString) -> [TranslationPart] {
        output.runs[\.link].map { link, range in
            let text = String(output[range].characters)
            if let link, link.scheme == partScheme, let id = Int(link.absoluteString.dropFirst(partScheme.count + 1)) {
                return .preserved(text, id: id)
            }
            return .text(text)
        }
    }
}
