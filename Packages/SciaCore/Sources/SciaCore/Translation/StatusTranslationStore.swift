import Foundation
import MemoryCache
import os

/// 段落を訳す部品。OSの翻訳と、テスト用の偽物を差し替える境界。
public protocol StatusTranslating: Sendable {
    /// `parts`を`source`の言語から`target`の言語へ`strategy`の方式で訳す。言語モデルが入っていなければ`StatusTranslationError.notInstalled`を投げる。
    func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart]
}

/// タイムラインの投稿の本文の自動翻訳。訳す順番と、訳文と、原文に戻した投稿を持つ。決まりはdocs/auto-translation.mdにある。
@MainActor
public final class StatusTranslationStore {
    /// 訳文を届けたか、訳せないと分かったか、原文と訳文を切り替えた投稿を知らせる。
    public var onChange: ((Set<Status.ID>) -> Void)?

    private struct Entry {
        /// 訳した時点の本文。編集で変わったら、この訳文は使わない。
        let content: String
        let richText: RichText
    }

    private let translator: any StatusTranslating
    private var targetLanguage: String
    private var strategy: TranslationStrategy
    /// 翻訳先を変えるたびに増やす。訳している途中で変えたら、元の翻訳先に戻していても、その結果を捨てるため。
    private var targetGeneration = 0
    private let scope: TaskScope
    private let clock: any Clock<Duration>
    private let applyInterval: () -> Duration

    /// 訳す言語。地域や文字を除いた言語のコード。
    private var languages: Set<String> = []
    private var entries = CostLimitedCache<Status.ID, Entry>(totalCostLimit: StatusTranslationStore.cacheCostLimit)
    private var originals: Set<Status.ID> = []
    /// 言語モデルが入っていないと分かった言語。訳せた時点で外す。
    private var uninstalledLanguages: Set<String> = []
    /// 訳せなかった投稿と、そのときの本文。本文が変わるか、訳す言語が変わるまで、訳し直さない。
    private var skipped = CostLimitedCache<Status.ID, String>(totalCostLimit: StatusTranslationStore.cacheCostLimit)
    /// これから訳す投稿。先頭から訳す。
    private var wanted: [Status] = []
    private var changed: Set<Status.ID> = []

    private static let logger = SciaLog.logger(category: "translation")
    /// 持っておく訳文の文字数の合計。
    private static let cacheCostLimit = 2_000_000

    /// - Parameters:
    ///   - targetLanguage: 翻訳先の言語。
    ///   - strategy: 翻訳の方式。
    ///   - scope: 翻訳の処理の持ち主。
    ///   - applyInterval: 訳文が届いてから画面へ知らせるまでの間。続けて届いた訳文を、まとめて描き直すため。
    public init(
        translator: any StatusTranslating,
        targetLanguage: String,
        strategy: TranslationStrategy,
        scope: TaskScope,
        clock: any Clock<Duration> = SystemTime.clock,
        applyInterval: @escaping () -> Duration
    ) {
        self.translator = translator
        self.targetLanguage = targetLanguage
        self.strategy = strategy
        self.scope = scope
        self.clock = clock
        self.applyInterval = applyInterval
    }

    /// 訳す言語を置き換える。訳せなかった投稿は、訳せるようになっているかもしれないので忘れる。訳している途中の投稿の結果は捨てる。
    public func setLanguages(_ codes: some Sequence<String>) {
        languages = Set(codes.compactMap(Self.matchKey))
        targetGeneration += 1
        skipped = CostLimitedCache(totalCostLimit: Self.cacheCostLimit)
        uninstalledLanguages = []
    }

    /// 翻訳先を置き換える。持っている訳文を捨てて訳し直す。
    public func setTargetLanguage(_ language: String) {
        guard language != targetLanguage else { return }
        targetLanguage = language
        discardTranslations()
    }

    /// 翻訳の方式を置き換える。持っている訳文を捨てて訳し直す。
    public func setStrategy(_ strategy: TranslationStrategy) {
        guard strategy != self.strategy else { return }
        self.strategy = strategy
        discardTranslations()
    }

    /// 持っている訳文と訳せなかった投稿を忘れ、頼まれていた投稿を取り下げる。訳している途中の投稿の結果は捨てる。
    private func discardTranslations() {
        targetGeneration += 1
        entries = CostLimitedCache(totalCostLimit: Self.cacheCostLimit)
        skipped = CostLimitedCache(totalCostLimit: Self.cacheCostLimit)
        uninstalledLanguages = []
        wanted = []
    }

    /// `statuses`を、この順で訳すよう頼む。前に頼んでまだ訳していないものは取り下げる。ブーストなら元の投稿を渡す。
    public func request(_ statuses: [Status]) {
        wanted = statuses.filter(needsTranslation)
        guard !wanted.isEmpty else { return }
        scope.run(key: "translate", .skippingWhileRunning, .display) { [weak self] in
            await self?.translateWanted()
        }
    }

    /// `status`の本文を訳文で出すなら、その訳文を返す。ブーストなら元の投稿を渡す。
    public func translation(for status: Status) -> RichText? {
        guard !originals.contains(status.id) else { return nil }
        return currentEntry(for: status)?.richText
    }

    /// `status`の訳文を持っているか。原文に戻していても、持っていればtrue。
    public func hasTranslation(of status: Status) -> Bool {
        currentEntry(for: status) != nil
    }

    /// `status`の訳文を待っているか。本文のない投稿は、訳すものがないので待たない。ブーストなら元の投稿を渡す。
    public func isTranslating(_ status: Status) -> Bool {
        guard needsTranslation(status), !originals.contains(status.id), !status.content.isEmpty else { return false }
        return !uninstalledLanguages.contains(status.language.flatMap(Self.matchKey) ?? "")
    }

    public func isShowingOriginal(_ status: Status) -> Bool {
        originals.contains(status.id)
    }

    /// 原文と訳文を切り替える。
    public func toggleOriginal(of status: Status) {
        if originals.remove(status.id) == nil {
            originals.insert(status.id)
        }
        onChange?([status.id])
    }

    private func currentEntry(for status: Status) -> Entry? {
        guard isTranslatable(status), let entry = entries.value(forKey: status.id), entry.content == status.content else { return nil }
        return entry
    }

    private func isTranslatable(_ status: Status) -> Bool {
        guard let code = status.language.flatMap(Self.matchKey), languages.contains(code) else { return false }
        return status.language.flatMap(Self.languageCode) != Self.languageCode(targetLanguage)
    }

    private func needsTranslation(_ status: Status) -> Bool {
        isTranslatable(status) && currentEntry(for: status) == nil && skipped.value(forKey: status.id) != status.content
    }

    /// 投稿の言語と訳す言語を比べるキー。`zh`と`zh-CN`のように同じ言語は同じキーになり、`zh`と`zh-TW`、`en`と`en-GB`は別のキーになる。
    private static func matchKey(_ identifier: String) -> String? {
        Locale.Language(identifier: identifier).maximalIdentifier
    }

    private static func languageCode(_ identifier: String) -> String? {
        Locale.Language(identifier: identifier).languageCode?.identifier
    }

    private func translateWanted() async {
        while !Task.isCancelled, let status = nextWanted(), let language = status.language {
            let generation = targetGeneration
            do {
                let richText = try await Self.translate(status, language: language, translator: translator, target: targetLanguage, strategy: strategy)
                guard !Task.isCancelled else { return }
                guard generation == targetGeneration else { continue }
                if let richText {
                    if let code = Self.matchKey(language) { uninstalledLanguages.remove(code) }
                    _ = entries.setValue(Entry(content: status.content, richText: richText), forKey: status.id, cost: status.content.utf8.count)
                    noteChange([status.id])
                } else {
                    skip(status)
                }
            } catch StatusTranslationError.notInstalled {
                guard generation == targetGeneration else { continue }
                // 同じ言語の残りは試さない。ダウンロードがいつ終わっても訳せるよう、次に頼まれたときは試す。
                let code = Self.matchKey(language)
                let sameLanguage = wanted.filter { $0.language.flatMap(Self.matchKey) == code }
                wanted.removeAll { $0.language.flatMap(Self.matchKey) == code }
                if let code, uninstalledLanguages.insert(code).inserted {
                    noteChange(Set(sameLanguage.map(\.id)).union([status.id]))
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("translation skipped id=\(status.id, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                guard generation == targetGeneration else { continue }
                skip(status)
            }
        }
    }

    private func skip(_ status: Status) {
        _ = skipped.setValue(status.content, forKey: status.id, cost: status.content.utf8.count)
        noteChange([status.id])
    }

    private func nextWanted() -> Status? {
        while !wanted.isEmpty {
            let status = wanted.removeFirst()
            if needsTranslation(status) { return status }
        }
        return nil
    }

    /// 訳文を返す。訳す段落がなければnil。本文を読むのが重いので、メインスレッドの外で走らせる。
    @concurrent
    private nonisolated static func translate(
        _ status: Status,
        language: String,
        translator: any StatusTranslating,
        target: String,
        strategy: TranslationStrategy
    ) async throws -> RichText? {
        guard let plan = RichTextTranslationPlan(.status(status)) else { return nil }
        var translated: [[TranslationPart]] = []
        for paragraph in plan.paragraphs {
            translated.append(try await translator.translate(paragraph, from: language, to: target, strategy: strategy))
        }
        return try plan.applying(translated)
    }

    private func noteChange(_ ids: Set<Status.ID>) {
        changed.formUnion(ids)
        let interval = applyInterval()
        scope.run(key: "apply", .skippingWhileRunning, .display) { [weak self, clock] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            self?.deliverChanges()
        }
    }

    private func deliverChanges() {
        let ids = changed
        changed = []
        guard !ids.isEmpty else { return }
        onChange?(ids)
    }
}
