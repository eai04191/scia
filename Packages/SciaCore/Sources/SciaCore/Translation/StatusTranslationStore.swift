import Foundation
import MemoryCache

/// 段落を訳す部品。OSの翻訳と、テスト用の偽物を差し替える境界。
public protocol StatusTranslating: Sendable {
    /// `parts`を`source`の言語から`target`の言語へ訳す。言語モデルが入っていなければ`StatusTranslationError.notInstalled`を投げる。
    func translate(_ parts: [TranslationPart], from source: String, to target: String) async throws -> [TranslationPart]
}

/// タイムラインの投稿の本文の自動翻訳。訳す順番と、訳文と、原文に戻した投稿を持つ。決まりはdocs/auto-translation.mdにある。
@MainActor
public final class StatusTranslationStore {
    /// 訳文を届けたか、原文と訳文を切り替えた投稿を知らせる。
    public var onChange: ((Set<Status.ID>) -> Void)?

    private struct Entry {
        /// 訳した時点の本文。編集で変わったら、この訳文は使わない。
        let content: String
        let richText: RichText
    }

    private let translator: any StatusTranslating
    private let targetLanguage: String
    private let scope: TaskScope
    private let clock: any Clock<Duration>
    private let applyInterval: () -> Duration

    /// 訳す言語。地域や文字を除いた言語のコード。
    private var languages: Set<String> = []
    private var entries = CostLimitedCache<Status.ID, Entry>(totalCostLimit: StatusTranslationStore.cacheCostLimit)
    private var originals: Set<Status.ID> = []
    /// 訳せなかった投稿。訳す言語が変わるまで、訳し直さない。
    private var skipped: Set<Status.ID> = []
    /// 言語モデルが入っていなかった言語。訳す言語が変わるまで、試さない。
    private var unavailableLanguages: Set<String> = []
    /// これから訳す投稿。先頭から訳す。
    private var wanted: [Status] = []
    private var changed: Set<Status.ID> = []

    /// 持っておく訳文の文字数の合計。
    private static let cacheCostLimit = 2_000_000

    /// - Parameters:
    ///   - targetLanguage: 翻訳先の言語。端末の言語。
    ///   - scope: 翻訳の処理の持ち主。
    ///   - applyInterval: 訳文が届いてから画面へ知らせるまでの間。続けて届いた訳文を、まとめて描き直すため。
    public init(
        translator: any StatusTranslating,
        targetLanguage: String,
        scope: TaskScope,
        clock: any Clock<Duration> = SystemTime.clock,
        applyInterval: @escaping () -> Duration
    ) {
        self.translator = translator
        self.targetLanguage = targetLanguage
        self.scope = scope
        self.clock = clock
        self.applyInterval = applyInterval
    }

    /// 訳す言語を置き換える。訳せなかった投稿と言語は、ダウンロードで訳せるようになるので忘れる。
    public func setLanguages(_ codes: some Sequence<String>) {
        languages = Set(codes.compactMap(Self.languageCode))
        skipped = []
        unavailableLanguages = []
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
        guard let code = status.language.flatMap(Self.languageCode), languages.contains(code) else { return false }
        return code != Self.languageCode(targetLanguage)
    }

    private func needsTranslation(_ status: Status) -> Bool {
        guard isTranslatable(status), currentEntry(for: status) == nil, !skipped.contains(status.id) else { return false }
        return status.language.flatMap(Self.languageCode).map { !unavailableLanguages.contains($0) } ?? false
    }

    private static func languageCode(_ identifier: String) -> String? {
        Locale.Language(identifier: identifier).languageCode?.identifier
    }

    private func translateWanted() async {
        while !Task.isCancelled, let status = nextWanted(), let language = status.language {
            do {
                let richText = try await Self.translate(status, language: language, translator: translator, target: targetLanguage)
                guard !Task.isCancelled else { return }
                if let richText {
                    _ = entries.setValue(Entry(content: status.content, richText: richText), forKey: status.id, cost: status.content.utf8.count)
                    noteChange(status.id)
                } else {
                    skipped.insert(status.id)
                }
            } catch StatusTranslationError.notInstalled {
                if let code = Self.languageCode(language) {
                    unavailableLanguages.insert(code)
                }
            } catch is CancellationError {
                return
            } catch {
                skipped.insert(status.id)
            }
        }
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
        target: String
    ) async throws -> RichText? {
        guard let plan = RichTextTranslationPlan(.status(status)) else { return nil }
        var translated: [[TranslationPart]] = []
        for paragraph in plan.paragraphs {
            translated.append(try await translator.translate(paragraph, from: language, to: target))
        }
        return try plan.applying(translated)
    }

    private func noteChange(_ id: Status.ID) {
        changed.insert(id)
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
