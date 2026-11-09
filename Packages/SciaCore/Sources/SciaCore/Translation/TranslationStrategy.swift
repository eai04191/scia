/// 自動翻訳に使うモデルの方式（docs/auto-translation.md）。
public enum TranslationStrategy: String, Codable, CaseIterable, Sendable {
    /// Apple Intelligenceのモデルで訳す。使えない端末では、OSが`lowLatency`のモデルに切り替える。
    case highFidelity
    /// 従来のモデルで訳す。
    case lowLatency
}
