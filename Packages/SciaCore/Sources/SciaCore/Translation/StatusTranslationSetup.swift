/// 自動翻訳のうち、UIが用意するもの。`AccountSession`に渡すと、セッションが`StatusTranslationStore`を作って持つ。
/// 翻訳先と方式は、設定とOSの状態（使える翻訳の仕組み）から決まるので、UIが決めて返す。Observationで追える値から決めれば、変わったときにセッションがストアへ入れ直す。
public struct StatusTranslationSetup {
    public var translator: any StatusTranslating
    /// 翻訳先の言語のコード。
    public var targetLanguage: @MainActor () -> String
    public var strategy: @MainActor () -> TranslationStrategy

    public init(translator: any StatusTranslating, targetLanguage: @escaping @MainActor () -> String, strategy: @escaping @MainActor () -> TranslationStrategy) {
        self.translator = translator
        self.targetLanguage = targetLanguage
        self.strategy = strategy
    }
}
