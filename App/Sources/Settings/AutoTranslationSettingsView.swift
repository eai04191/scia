import SciaCore
import SwiftUI
import Translation

/// 自動で訳す投稿の言語を選ぶ画面。決まりはdocs/auto-translation.mdの「言語のダウンロード」にある。
@available(iOS 26.4, *)
struct AutoTranslationSettingsView: View {
    private struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    @Bindable var settings: AppSettings
    @State private var languages: [Language] = []
    /// ダウンロードの許可を求める言語の組み合わせ。入れるとOSのシートを出す。
    @State private var download: TranslationSession.Configuration?
    @State private var downloadingCode: String?

    private let target = Locale.current.language

    var body: some View {
        Form {
            Section {
                ForEach(languages) { language in
                    Toggle(language.name, isOn: isOn(language))
                }
            } footer: {
                Text("オンにした言語の投稿の本文を、タイムラインで\(targetName)に翻訳します。翻訳はデバイス上で行います。")
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("自動翻訳")
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) { await loadLanguages() }
        .translationTask(download) { @concurrent [settings, downloadingCode] session in
            do {
                try await session.prepareTranslation()
            } catch {
                // シートを閉じて許可しなかった言語は、訳せないのでオフに戻す。
                await MainActor.run {
                    settings.autoTranslationLanguages.removeAll { $0 == downloadingCode }
                }
            }
        }
    }

    private var targetName: String {
        target.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? target.minimalIdentifier
    }

    private func isOn(_ language: Language) -> Binding<Bool> {
        Binding {
            settings.autoTranslationLanguages.contains(language.code)
        } set: { isOn in
            if isOn {
                settings.autoTranslationLanguages.append(language.code)
                Task(.withoutRequests) { await requestDownload(of: language.code) }
            } else {
                settings.autoTranslationLanguages.removeAll { $0 == language.code }
            }
        }
    }

    private func loadLanguages() async {
        let codes = await Self.supportedLanguageCodes().subtracting([target.languageCode?.identifier].compactMap(\.self))
        languages = codes
            .map { Language(code: $0, name: Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @concurrent
    private nonisolated static func supportedLanguageCodes() async -> Set<String> {
        #if DEBUG
        if DebugStatusTranslator.isFake { return ["en", "ko", "de"] }
        #endif
        return Set(await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier })
    }

    @concurrent
    private nonisolated static func isInstalled(source: Locale.Language, target: Locale.Language) async -> Bool {
        #if DEBUG
        if DebugStatusTranslator.isFake { return true }
        #endif
        return await LanguageAvailability().status(from: source, to: target) == .installed
    }

    private func requestDownload(of code: String) async {
        let source = Locale.Language(identifier: code)
        guard await !Self.isInstalled(source: source, target: target) else { return }
        downloadingCode = code
        let configuration = TranslationSession.Configuration(source: source, target: target)
        // 許可しなかった言語をもう一度オンにしたときは同じ組み合わせになるので、無効にして求め直す。
        if download == configuration {
            download?.invalidate()
        } else {
            download = configuration
        }
    }
}
