import Foundation
import SciaCore
import Translation
import os

@available(iOS 26.4, *)
extension TranslationSession.Strategy {
    init(_ strategy: TranslationStrategy) {
        self = switch strategy {
        case .highFidelity: .highFidelity
        case .lowLatency: .lowLatency
        }
    }
}

/// OSのTranslationフレームワークで段落を訳す。ダウンロードは求めず、言語モデルがなければ`notInstalled`を投げる（docs/auto-translation.md）。
@available(iOS 26.4, *)
struct SystemStatusTranslator: StatusTranslating {
    /// 残す部分に付けるリンクのスキーム。訳文の中で、どの部分が元のどれかを見分ける。
    private static let partScheme = "scia-translation-part"
    private static let logger = SciaLog.logger(category: "translation")

    func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart] {
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target), preferredStrategy: TranslationSession.Strategy(strategy))
        do {
            guard let output = try await session.translate(Self.attributedString(from: parts)).attributedTargetText else {
                Self.log(cause: "noAttributedText", source: source, strategy: strategy)
                throw StatusTranslationError.preservedPartsChanged
            }
            return Self.parts(from: output)
        } catch let error where TranslationError.notInstalled ~= error {
            Self.log(cause: "notInstalled", source: source, strategy: strategy)
            throw StatusTranslationError.notInstalled
        } catch let error as TranslationError {
            Self.log(cause: Self.cause(of: error), source: source, strategy: strategy)
            throw error
        }
    }

    private static func log(cause: String, source: String, strategy: TranslationStrategy) {
        let language = Locale.Language(identifier: source).languageCode?.identifier ?? "unknown"
        logger.error("translation failed language=\(language, privacy: .public) strategy=\(strategy.rawValue, privacy: .public) cause=\(cause, privacy: .public)")
    }

    private static func cause(of error: TranslationError) -> String {
        if TranslationError.unsupportedSourceLanguage ~= error { return "unsupportedSourceLanguage" }
        if TranslationError.unsupportedTargetLanguage ~= error { return "unsupportedTargetLanguage" }
        if TranslationError.unsupportedLanguagePairing ~= error { return "unsupportedLanguagePairing" }
        if TranslationError.unableToIdentifyLanguage ~= error { return "unableToIdentifyLanguage" }
        if TranslationError.nothingToTranslate ~= error { return "nothingToTranslate" }
        if TranslationError.internalError ~= error { return "internalError" }
        return "other"
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
