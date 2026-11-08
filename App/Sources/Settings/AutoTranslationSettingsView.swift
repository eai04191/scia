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
    }

    /// 入れるとOSのシートを出す。
    private(set) var configuration: TranslationSession.Configuration?
    private var current: Request?
    private var waiting: [Request] = []
    private let onRefused: (Request) -> Void

    init(onRefused: @escaping (Request) -> Void) {
        self.onRefused = onRefused
    }

    /// `target`への求めを待ち行列に足す。ほかの翻訳先への求めは、もう要らないので外す。シートを出していなければ、先頭を出す。
    func enqueue(_ requests: [Request], target: Locale.Language) {
        waiting.removeAll { $0.target != target }
        waiting += requests.filter { !waiting.contains($0) && $0 != current }
        if current == nil { showNext() }
    }

    /// シートの結果を受け取り、次を出す。
    func finish(granted: Bool) {
        if !granted, let current { onRefused(current) }
        current = nil
        showNext()
    }

    private func showNext() {
        guard !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        current = request
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: request.source), target: request.target)
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
    @State private var supportedCodes: Set<String> = []
    @State private var downloads: TranslationDownloadQueue

    init(settings: AppSettings) {
        self.settings = settings
        // シートを閉じて許可しなかった言語は、訳せないのでオフに戻す。
        _downloads = State(initialValue: TranslationDownloadQueue { request in
            guard request.target == settings.resolvedTranslationTarget else { return }
            settings.autoTranslationLanguages.removeAll { $0 == request.source }
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("翻訳先", selection: $settings.autoTranslationTarget) {
                    Text("デバイスの言語（\(Self.name(of: Locale.current.language))）").tag(String?.none)
                    ForEach(targets) { language in
                        Text(language.name).tag(String?.some(language.code))
                    }
                }
                .pickerStyle(.navigationLink)
            }
            Section {
                ForEach(sources) { language in
                    Toggle(language.name, isOn: isOn(language))
                }
            } footer: {
                Text("オンにした言語の投稿の本文を、タイムラインで\(Self.name(of: target))に翻訳します。翻訳はデバイス上で行います。")
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
        let supported = await Self.supportedLanguages()
        targets = supported
            .map { Language(code: $0.minimalIdentifier, name: Self.name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        supportedCodes = Set(supported.compactMap { $0.languageCode?.identifier })
        updateSources()
    }

    /// 翻訳先の言語は、訳す投稿の言語に選べない。
    private func updateSources() {
        sources = supportedCodes.subtracting([target.languageCode?.identifier].compactMap(\.self))
            .map { Language(code: $0, name: Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @concurrent
    private nonisolated static func supportedLanguages() async -> [Locale.Language] {
        #if DEBUG
        if DebugStatusTranslator.isFake { return ["en", "ko", "de", "ja"].map { Locale.Language(identifier: $0) } }
        #endif
        return await LanguageAvailability().supportedLanguages
    }

    @concurrent
    private nonisolated static func isInstalled(source: Locale.Language, target: Locale.Language) async -> Bool {
        #if DEBUG
        if DebugStatusTranslator.isFake { return true }
        #endif
        return await LanguageAvailability().status(from: source, to: target) == .installed
    }

    /// `codes`のうち、今の翻訳先への言語モデルが入っていないものの許可を求める。
    private func requestDownloads(of codes: [String]) async {
        let target = target
        var requests: [TranslationDownloadQueue.Request] = []
        for code in codes where code != target.languageCode?.identifier {
            if await !Self.isInstalled(source: Locale.Language(identifier: code), target: target) {
                requests.append(TranslationDownloadQueue.Request(source: code, target: target))
            }
        }
        // 調べている間に翻訳先が変わったら、新しい翻訳先の分に任せる。
        guard target == self.target else { return }
        downloads.enqueue(requests, target: target)
    }
}
