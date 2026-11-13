import Foundation
import MemoryCache
import os

/// 段落を訳す部品。OSの翻訳と、テスト用の偽物を差し替える境界。
public protocol StatusTranslating: Sendable {
    /// `parts`を`source`の言語から`target`の言語へ`strategy`の方式で訳す。言語モデルが入っていなければ`StatusTranslationError.notInstalled`を投げる。
    func translate(_ parts: [TranslationPart], from source: String, to target: String, strategy: TranslationStrategy) async throws -> [TranslationPart]
}

/// 自動翻訳で訳すもの。投稿の本文か、Xの投稿の本文。
public struct TranslationSource: Sendable {
    public enum ID: Hashable, Sendable {
        case status(Status.ID)
        case xPost(String)
    }

    public let id: ID
    /// 本文の言語。分からなければnil。
    public let language: String?
    /// 投稿した人の`acct`。Xの投稿ではnil。
    public let authorAcct: String?
    /// 訳した結果が使えるかを比べる本文。変われば訳し直す。空なら訳すものがない。
    let content: String
    let richText: @Sendable () -> RichText

    /// ブーストなら元の投稿を渡す。
    public init(_ status: Status) {
        id = .status(status.id)
        language = status.language
        authorAcct = status.account.acct
        content = status.content
        richText = { .status(status) }
    }

    public init(_ post: XPost) {
        id = .xPost(post.id)
        language = post.language
        authorAcct = nil
        content = post.text.plainText
        richText = { post.text }
    }

    /// ログに出すID。
    var logID: String {
        switch id {
        case .status(let id): id
        case .xPost(let id): "x:\(id)"
        }
    }

    /// 言語か本文が変われば、別の値になる。
    var signature: String {
        "\(language ?? "")\n\(content)"
    }
}

/// タイムラインの投稿の本文、引用元の本文、Xの投稿の本文の自動翻訳。訳す順番と、訳文と、原文に戻した投稿を持つ。決まりはdocs/auto-translation.mdにある。
@MainActor
public final class StatusTranslationStore {
    /// 訳文を届けたか、訳せないと分かったか、原文と訳文を切り替えた投稿を知らせる。
    public var onChange: ((Set<TranslationSource.ID>) -> Void)?

    private struct Entry {
        /// 訳した時点の言語と本文。編集で変わったら、この訳文は使わない。
        let source: String
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
    /// 訳さない人。小文字にした`username@domain`。
    private var excludedAuthors: Set<String> = []
    /// ログインしているサーバーの名前。同じサーバーの人の`acct`に補う。
    private var localServer = ""
    private var entries = CostLimitedCache<TranslationSource.ID, Entry>(totalCostLimit: StatusTranslationStore.cacheCostLimit)
    private var originals: Set<TranslationSource.ID> = []
    /// 言語モデルが入っていないと分かった言語。訳せた時点で外す。
    private var uninstalledLanguages: Set<String> = []
    /// 訳せなかった投稿と、そのときの本文。本文が変わるか、訳す言語が変わるまで、訳し直さない。
    private var skipped = CostLimitedCache<TranslationSource.ID, String>(totalCostLimit: StatusTranslationStore.cacheCostLimit)
    /// 訳したハッシュタグと、併記する訳。併記しないものは空の文字。訳した言語ごとに持つ。
    private var hashtagGlosses: [String: [String: String]] = [:]
    /// これから訳す投稿。先頭から訳す。
    private var wanted: [TranslationSource] = []
    private var changed: Set<TranslationSource.ID> = []

    private nonisolated static let logger = SciaLog.logger(category: "translation")
    /// 持っておく訳文の文字数の合計。
    private static let cacheCostLimit = 2_000_000
    /// 持っておくハッシュタグの訳の数。超えたら、すべて忘れて訳し直す。
    private static let hashtagGlossLimit = 5_000

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

    /// 訳さない人を置き換える。訳文は捨てず、対象外にしている間だけ出さない。
    /// - Parameters:
    ///   - handles: `username@domain`の形のハンドル。大文字と小文字は区別しない。
    ///   - localServer: ログインしているサーバーの名前。
    public func setExcludedAuthors(_ handles: some Sequence<String>, localServer: String) {
        excludedAuthors = Set(handles.map { $0.lowercased() })
        self.localServer = localServer
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
        hashtagGlosses = [:]
        wanted = []
    }

    /// `sources`を、この順で訳すよう頼む。前に頼んでまだ訳していないものは取り下げる。
    public func request(_ sources: [TranslationSource]) {
        wanted = sources.filter(needsTranslation)
        guard !wanted.isEmpty else { return }
        scope.run(key: "translate", .skippingWhileRunning, .display) { [weak self] in
            await self?.translateWanted()
        }
    }

    /// `source`の本文を訳文で出すなら、その訳文を返す。
    public func translation(for source: TranslationSource) -> RichText? {
        guard !originals.contains(source.id) else { return nil }
        return currentEntry(for: source)?.richText
    }

    /// `source`の訳文を持っているか。原文に戻していても、持っていればtrue。
    public func hasTranslation(of source: TranslationSource) -> Bool {
        currentEntry(for: source) != nil
    }

    /// `source`の訳文を待っているか。本文がなければ、訳すものがないので待たない。
    public func isTranslating(_ source: TranslationSource) -> Bool {
        guard needsTranslation(source), !originals.contains(source.id) else { return false }
        return !uninstalledLanguages.contains(source.language.flatMap(Self.matchKey) ?? "")
    }

    public func isShowingOriginal(_ source: TranslationSource) -> Bool {
        originals.contains(source.id)
    }

    /// 原文と訳文を切り替える。
    public func toggleOriginal(of source: TranslationSource) {
        if originals.remove(source.id) == nil {
            originals.insert(source.id)
        }
        onChange?([source.id])
    }

    private func currentEntry(for source: TranslationSource) -> Entry? {
        guard isTranslatable(source), let entry = entries.value(forKey: source.id), entry.source == source.signature else { return nil }
        return entry
    }

    private func isTranslatable(_ source: TranslationSource) -> Bool {
        guard let code = source.language.flatMap(Self.matchKey), languages.contains(code) else { return false }
        if !excludedAuthors.isEmpty, let acct = source.authorAcct, excludedAuthors.contains(UserHandle(acct: acct, localServer: localServer).fullAcct.lowercased()) {
            return false
        }
        return source.language.flatMap(Self.languageCode) != Self.languageCode(targetLanguage)
    }

    private func needsTranslation(_ source: TranslationSource) -> Bool {
        !source.content.isEmpty && isTranslatable(source) && currentEntry(for: source) == nil && skipped.value(forKey: source.id) != source.signature
    }

    /// 投稿の言語と訳す言語を比べるキー。`zh`と`zh-CN`のように同じ言語は同じキーになり、`zh`と`zh-TW`、`en`と`en-GB`は別のキーになる。
    private static func matchKey(_ identifier: String) -> String? {
        Locale.Language(identifier: identifier).maximalIdentifier
    }

    private static func languageCode(_ identifier: String) -> String? {
        Locale.Language(identifier: identifier).languageCode?.identifier
    }

    private func translateWanted() async {
        while !Task.isCancelled, let source = nextWanted(), let language = source.language {
            let generation = targetGeneration
            do {
                let known = hashtagGlosses[language] ?? [:]
                let (richText, glosses) = try await Self.translate(source, language: language, translator: translator, target: targetLanguage, strategy: strategy, knownGlosses: known)
                guard !Task.isCancelled else { return }
                guard generation == targetGeneration else { continue }
                rememberGlosses(glosses, language: language)
                if let richText {
                    if let code = Self.matchKey(language) { uninstalledLanguages.remove(code) }
                    _ = entries.setValue(Entry(source: source.signature, richText: richText), forKey: source.id, cost: source.content.utf8.count)
                    noteChange([source.id])
                } else {
                    skip(source)
                }
            } catch StatusTranslationError.notInstalled {
                guard generation == targetGeneration else { continue }
                // 同じ言語の残りは試さない。ダウンロードがいつ終わっても訳せるよう、次に頼まれたときは試す。
                let code = Self.matchKey(language)
                let sameLanguage = wanted.filter { $0.language.flatMap(Self.matchKey) == code }
                wanted.removeAll { $0.language.flatMap(Self.matchKey) == code }
                if let code, uninstalledLanguages.insert(code).inserted {
                    noteChange(Set(sameLanguage.map(\.id)).union([source.id]))
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("translation skipped id=\(source.logID, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                guard generation == targetGeneration else { continue }
                skip(source)
            }
        }
    }

    private func skip(_ source: TranslationSource) {
        _ = skipped.setValue(source.signature, forKey: source.id, cost: source.content.utf8.count)
        noteChange([source.id])
    }

    private func nextWanted() -> TranslationSource? {
        while !wanted.isEmpty {
            let source = wanted.removeFirst()
            if needsTranslation(source) { return source }
        }
        return nil
    }

    private func rememberGlosses(_ glosses: [String: String], language: String) {
        guard !glosses.isEmpty else { return }
        if hashtagGlosses.values.reduce(glosses.count, { $0 + $1.count }) > Self.hashtagGlossLimit {
            hashtagGlosses = [:]
        }
        hashtagGlosses[language, default: [:]].merge(glosses) { _, new in new }
    }

    /// 訳文と、新しく訳したハッシュタグの訳を返す。訳す段落も併記する訳もなければ、訳文はnil。本文を読むのが重いので、メインスレッドの外で走らせる。
    /// - Parameter knownGlosses: 前に訳したハッシュタグの訳。ここにあるものは訳し直さない。
    @concurrent
    private nonisolated static func translate(
        _ source: TranslationSource,
        language: String,
        translator: any StatusTranslating,
        target: String,
        strategy: TranslationStrategy,
        knownGlosses: [String: String]
    ) async throws -> (richText: RichText?, glosses: [String: String]) {
        guard let plan = RichTextTranslationPlan(source.richText()) else { return (nil, [:]) }
        var translated: [[TranslationPart]] = []
        for paragraph in plan.paragraphs {
            translated.append(try await translator.translate(paragraph, from: language, to: target, strategy: strategy))
        }
        var newGlosses: [String: String] = [:]
        var suffixes: [String: String] = [:]
        for name in plan.hashtags {
            var gloss = knownGlosses[name]
            if gloss == nil, let words = HashtagGloss.words(of: name) {
                do {
                    let parts = try await translator.translate([.text(words)], from: language, to: target, strategy: strategy)
                    let text = parts.map { part in
                        switch part {
                        case .text(let text), .preserved(let text, _): text
                        }
                    }.joined()
                    gloss = HashtagGloss.gloss(translated: text, name: name) ?? ""
                    newGlosses[name] = gloss
                } catch let error where !(error is CancellationError) && error as? StatusTranslationError != .notInstalled {
                    // ハッシュタグの訳だけが失敗しても、本文の訳は使う。覚えないので、次にこのハッシュタグが出たら訳し直す。
                    logger.error("hashtag gloss skipped id=\(source.logID, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                }
            }
            if let gloss, !gloss.isEmpty {
                suffixes[name] = HashtagGloss.suffix(gloss, target: target)
            }
        }
        guard !plan.paragraphs.isEmpty || !suffixes.isEmpty else { return (nil, newGlosses) }
        return (try plan.applying(translated, hashtagSuffixes: suffixes), newGlosses)
    }

    private func noteChange(_ ids: Set<TranslationSource.ID>) {
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
