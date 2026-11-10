import FoundationModels
import SciaCore

/// Apple Intelligenceのモデルが今使えるか。使えないデバイスでは、翻訳モードの「Apple Intelligence」が「標準」のモデルで訳すため、選べないようにする。
/// Translationフレームワークはどのモデルで訳すかを返さないので、FoundationModelsのモデルが使えるかで見分ける。
enum AppleIntelligence {
    static var isAvailable: Bool {
        #if DEBUG
        if DebugStatusTranslator.isFake { return true }
        #endif
        return SystemLanguageModel.default.availability == .available
    }
}

extension AppSettings {
    /// 自動翻訳の翻訳モード。Apple Intelligenceが使えない間は、選んでいても「標準」。選んだことは残す。
    var resolvedTranslationStrategy: TranslationStrategy {
        AppleIntelligence.isAvailable ? autoTranslationStrategy : .lowLatency
    }
}
