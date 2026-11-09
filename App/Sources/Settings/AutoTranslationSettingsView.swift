import Observation
import SciaCore
import SwiftUI
import Translation

extension AppSettings {
    /// 自動翻訳の翻訳先。選んでいなければデバイスの言語。
    var resolvedTranslationTarget: Locale.Language {
        autoTranslationTarget.map { Locale.Language(identifier: $0) } ?? Locale.current.language
    }
}

/// ダウンロードの許可を、言語の組み合わせごとに順に求める。OSのシートは1つずつしか出せないため。
@available(iOS 26.4, *)
@MainActor
@Observable
private final class TranslationDownloadQueue {
    struct Request: Equatable {
        let source: String
        let target: Locale.Language
        let strategy: TranslationStrategy
    }

    /// 入れるとOSのシートを出す。
    private(set) var configuration: TranslationSession.Configuration?
    private var current: Request?
    private var waiting: [Request] = []
    private let onRefused: (Request) -> Void
    private let onInstalled: () -> Void

    init(onRefused: @escaping (Request) -> Void, onInstalled: @escaping () -> Void) {
        self.onRefused = onRefused
        self.onInstalled = onInstalled
    }

    /// `target`と`strategy`への求めを待ち行列に足す。ほかの翻訳先や方式への求めは、もう要らないので外す。シートを出していなければ、先頭を出す。
    func enqueue(_ requests: [Request], target: Locale.Language, strategy: TranslationStrategy) {
        waiting.removeAll { $0.target != target || $0.strategy != strategy }
        waiting += requests.filter { !waiting.contains($0) && $0 != current }
        if current == nil { showNext() }
    }

    /// まだ出していない求めを取り下げる。
    func withdrawWaiting() {
        waiting = []
    }

    /// シートの結果を受け取り、次を出す。
    func finish(granted: Bool) {
        if granted {
            onInstalled()
        } else if let current {
            onRefused(current)
        }
        current = nil
        showNext()
    }

    private func showNext() {
        guard !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        current = request
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: request.source), target: request.target, preferredStrategy: TranslationSession.Strategy(request.strategy))
        // 許可しなかった組み合わせをもう一度求めるときは同じ値になるので、無効にして求め直す。
        if configuration == next {
            configuration?.invalidate()
        } else {
            configuration = next
        }
    }
}

/// 自動翻訳の翻訳先と、訳す投稿の言語を選ぶ画面。決まりはdocs/auto-translation.mdの「言語のダウンロード」にある。
@available(iOS 26.4, *)
struct AutoTranslationSettingsView: View {
    private struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    @Bindable var settings: AppSettings
    @State private var targets: [Language] = []
    @State private var sources: [Language] = []
    @State private var downloads: TranslationDownloadQueue

    init(settings: AppSettings) {
        self.settings = settings
        // シートを閉じて許可しなかった言語は、訳せないのでオフに戻す。
        _downloads = State(initialValue: TranslationDownloadQueue(onRefused: { request in
            guard settings.isAutoTranslationEnabled, request.target == settings.resolvedTranslationTarget, request.strategy == settings.autoTranslationStrategy else { return }
            settings.autoTranslationLanguages.removeAll { $0 == request.source }
        }, onInstalled: {
            settings.noteAutoTranslationModelInstalled()
        }))
    }

    var body: some View {
        Form {
            Section {
                Toggle("自動翻訳", isOn: $settings.isAutoTranslationEnabled.animation())
            }
            if settings.isAutoTranslationEnabled {
                options
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("自動翻訳")
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) { await loadLanguages() }
        .onChange(of: settings.autoTranslationTarget) {
            updateSources()
            Task(.withoutRequests) { await requestDownloads(of: settings.autoTranslationLanguages) }
        }
        .onChange(of: settings.isAutoTranslationEnabled) {
            guard settings.isAutoTranslationEnabled else {
                downloads.withdrawWaiting()
                return
            }
            Task(.withoutRequests) { await requestDownloads(of: settings.autoTranslationLanguages) }
        }
        .onChange(of: settings.autoTranslationStrategy) {
            Task(.withoutRequests) {
                await loadLanguages()
                await requestDownloads(of: settings.autoTranslationLanguages)
            }
        }
        .translationTask(downloads.configuration) { @concurrent [downloads] session in
            var granted = true
            do {
                try await session.prepareTranslation()
            } catch {
                granted = false
            }
            await downloads.finish(granted: granted)
        }
    }

    @ViewBuilder private var options: some View {
        Section {
            Picker("翻訳先", selection: $settings.autoTranslationTarget) {
                Text("デバイスの言語（\(Self.name(of: Locale.current.language))）").tag(String?.none)
                ForEach(targets) { language in
                    Text(language.name).tag(String?.some(language.code))
                }
            }
            .pickerStyle(.navigationLink)
            Picker("翻訳モード", selection: $settings.autoTranslationStrategy) {
                Text(verbatim: "Apple Intelligence").tag(TranslationStrategy.highFidelity)
                Text("標準").tag(TranslationStrategy.lowLatency)
            }
        }
        Section {
            ForEach(sources) { language in
                Toggle(language.name, isOn: isOn(language))
            }
        } header: {
            Text("翻訳元")
        }
    }

    private var target: Locale.Language { settings.resolvedTranslationTarget }

    private static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func isOn(_ language: Language) -> Binding<Bool> {
        Binding {
            settings.autoTranslationLanguages.contains(language.code)
        } set: { isOn in
            if isOn {
                settings.autoTranslationLanguages.append(language.code)
                Task(.withoutRequests) { await requestDownloads(of: [language.code]) }
            } else {
                settings.autoTranslationLanguages.removeAll { $0 == language.code }
            }
        }
    }

    private func loadLanguages() async {
        let supported = await Self.supportedLanguages(strategy: settings.autoTranslationStrategy)
        targets = supported
            .map { Language(code: $0.minimalIdentifier, name: Self.name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        updateSources()
    }

    /// 翻訳先の言語は、訳す投稿の言語に選べない。
    private func updateSources() {
        sources = targets.filter { Locale.Language(identifier: $0.code).languageCode != target.languageCode }
    }

    @concurrent
    private nonisolated static func supportedLanguages(strategy: TranslationStrategy) async -> [Locale.Language] {
        #if DEBUG
        if DebugStatusTranslator.isFake { return ["en", "ko", "de", "ja", "zh", "zh-TW"].map { Locale.Language(identifier: $0) } }
        #endif
        return await LanguageAvailability(preferredStrategy: TranslationSession.Strategy(strategy)).supportedLanguages
    }

    @concurrent
    private nonisolated static func needsDownload(source: Locale.Language, target: Locale.Language, strategy: TranslationStrategy) async -> Bool {
        #if DEBUG
        if DebugStatusTranslator.isFake { return false }
        #endif
        return await LanguageAvailability(preferredStrategy: TranslationSession.Strategy(strategy)).status(from: source, to: target) == .supported
    }

    /// `codes`のうち、今の翻訳先と方式でダウンロードすれば訳せるものの許可を求める。方式が対応していない言語は求めない。
    private func requestDownloads(of codes: [String]) async {
        let target = target
        let strategy = settings.autoTranslationStrategy
        var requests: [TranslationDownloadQueue.Request] = []
        for code in codes where Locale.Language(identifier: code).languageCode != target.languageCode {
            if await Self.needsDownload(source: Locale.Language(identifier: code), target: target, strategy: strategy) {
                requests.append(TranslationDownloadQueue.Request(source: code, target: target, strategy: strategy))
            }
        }
        // 調べている間にオフにしたら求めない。翻訳先か方式が変わったら、新しい設定の分に任せる。
        guard settings.isAutoTranslationEnabled, target == self.target, strategy == settings.autoTranslationStrategy else { return }
        downloads.enqueue(requests, target: target, strategy: strategy)
    }
}
