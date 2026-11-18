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

/// 自動翻訳の翻訳先と、訳す投稿の言語を選ぶ画面。決まりはdocs/auto-translation.mdの「言語のダウンロード」にある。
@available(iOS 26.4, *)
struct AutoTranslationSettingsView: View {
    private struct Language: Identifiable, Equatable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// 今の翻訳先と翻訳モードで、OSが対応している言語をモデルの有無で分けたもの。
    private struct Availability: Equatable {
        var targets: [Language] = []
        var installed: [Language] = []
        var downloadable: [Language] = []
    }

    /// 調べ直す対象。変わったら、前の対象の結果を待たずに調べ直す。
    private struct Subject: Equatable {
        let isEnabled: Bool
        /// 変わると翻訳モードの項目の出し方が変わるので、調べ直しも始め直す。
        let canUseAppleIntelligence: Bool
        let target: Locale.Language
        let strategy: TranslationStrategy
    }

    /// 開いている間にモデルの有無を調べ直す間隔。OSはダウンロードの完了を通知しないため。
    private static let pollingInterval: Duration = .seconds(2)

    @Bindable var settings: AppSettings
    var clock: any Clock<Duration> = AppDependencies.clock
    @State private var availability = Availability()
    /// `availability`を調べたときの対象。今の対象と違う間は、前の翻訳先や翻訳モードの並びなので出さない。
    @State private var loadedSubject: Subject?
    /// 入れるとOSのシートを出す。
    @State private var download: TranslationSession.Configuration?
    @State private var canUseAppleIntelligence = AppleIntelligence.isAvailable

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.isAutoTranslationEnabled.animation()) {
                    ModifiedLabel(title: SettingsTexts.AutoTranslation.toggle, isModified: settings.isModified(AutoTranslationSetting.enabled))
                }
                .contextMenu { resetButton(.enabled) }
            }
            if settings.isAutoTranslationEnabled {
                options
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle(SettingsPage.autoTranslation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests, id: subject) { await poll(subject) }
        .translationTask(download) { @concurrent session in
            // 許可してもしなくても同じに返るので、結果は見ない。入ったかは調べ直して知る。
            try? await session.prepareTranslation()
        }
    }

    @ViewBuilder private var options: some View {
        Section {
            Picker(selection: $settings.autoTranslationTarget) {
                Text(SettingsTexts.AutoTranslation.deviceLanguage(name: Self.name(of: Locale.current.language))).tag(String?.none)
                ForEach(availability.targets) { language in
                    Text(language.name).tag(String?.some(language.code))
                }
            } label: {
                ModifiedLabel(title: SettingsTexts.AutoTranslation.target, isModified: settings.isModified(AutoTranslationSetting.target))
            }
            .pickerStyle(.navigationLink)
            .contextMenu { resetButton(.target) }
            if canUseAppleIntelligence {
                // 情報ボタンを値の右（行の右端）に置くため、名前と選択を並べて組む。
                HStack(spacing: 8) {
                    Text(SettingsTexts.AutoTranslation.mode)
                    Spacer(minLength: 8)
                    // 選択の部品をそのまま置くと、部品の上下の余白で行がほかの行より高くなるので、余白のないメニューにする。
                    Menu {
                        Picker(SettingsTexts.AutoTranslation.mode, selection: $settings.autoTranslationStrategy) {
                            Text(TranslationStrategy.highFidelity.title).tag(TranslationStrategy.highFidelity)
                            Text(TranslationStrategy.lowLatency.title).tag(TranslationStrategy.lowLatency)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings.autoTranslationStrategy.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.medium))
                        }
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    .accessibilityLabel(SettingsTexts.AutoTranslation.mode)
                    .accessibilityValue(settings.autoTranslationStrategy.title)
                    NotInPresetInfoButton()
                }
            }
        }
        if loadedSubject == subject {
            languages
        }
        if !settings.autoTranslationExcludedHandles.isEmpty {
            Section {
                ForEach(settings.autoTranslationExcludedHandles, id: \.self) { handle in
                    Text(verbatim: "@\(handle)")
                }
                .onDelete { settings.autoTranslationExcludedHandles.remove(atOffsets: $0) }
            } header: {
                NotInPresetLabel(title: SettingsTexts.AutoTranslation.excludedUsers)
            }
        }
    }

    private func resetButton(_ setting: AutoTranslationSetting) -> some View {
        ResetButton(parentName: settings.parentPresetName, isModified: settings.isModified(setting)) { settings.reset(setting) }
    }

    @ViewBuilder private var languages: some View {
        if !availability.installed.isEmpty {
            Section {
                ForEach(availability.installed) { language in
                    Toggle(language.name, isOn: isOn(language))
                }
            } header: {
                NotInPresetLabel(title: SettingsTexts.AutoTranslation.installedHeader(usesSharedModel: usesSharedModel))
            } footer: {
                if !usesSharedModel {
                    ChevronPathText(SettingsTexts.AutoTranslation.removeLanguageFooter)
                        .accessibilityLabel(SettingsTexts.AutoTranslation.removeLanguageFooter.accessibilityLabel)
                }
            }
        }
        if !availability.downloadable.isEmpty {
            Section {
                ForEach(availability.downloadable) { language in
                    Button {
                        requestDownload(of: language)
                    } label: {
                        HStack {
                            Text(language.name).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "plus")
                        }
                    }
                    .accessibilityLabel(SettingsTexts.AutoTranslation.download(languageName: language.name))
                }
            } header: {
                NotInPresetLabel(title: SettingsTexts.AutoTranslation.downloadable)
            }
        }
    }

    /// Apple Intelligenceのモデルで訳していて、言語ごとのダウンロードも削除もない。
    private var usesSharedModel: Bool {
        subject.strategy == .highFidelity
    }

    private var subject: Subject {
        Subject(isEnabled: settings.isAutoTranslationEnabled, canUseAppleIntelligence: canUseAppleIntelligence, target: settings.resolvedTranslationTarget, strategy: settings.resolvedTranslationStrategy)
    }

    private nonisolated static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func isOn(_ language: Language) -> Binding<Bool> {
        Binding {
            settings.autoTranslationLanguages.contains(language.code)
        } set: { isOn in
            if isOn {
                settings.autoTranslationLanguages.append(language.code)
            } else {
                settings.autoTranslationLanguages.removeAll { $0 == language.code }
            }
        }
    }

    /// OSのシートでダウンロードの許可を求める。入ったらオンで並ぶよう、訳す言語に足しておく。
    private func requestDownload(of language: Language) {
        if !settings.autoTranslationLanguages.contains(language.code) {
            settings.autoTranslationLanguages.append(language.code)
        }
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: language.code), target: subject.target, preferredStrategy: TranslationSession.Strategy(subject.strategy))
        // 同じ言語をもう一度求めるときは同じ値になるので、無効にして求め直す。
        if download == next {
            download?.invalidate()
        } else {
            download = next
        }
    }

    /// 開いている間、モデルの有無を調べ直し続ける。
    private func poll(_ subject: Subject) async {
        guard subject.isEnabled else { return }
        var isFirst = true
        while !Task.isCancelled {
            if canUseAppleIntelligence != AppleIntelligence.isAvailable {
                // 対象が変わるので、調べ直しは始まり直す。
                canUseAppleIntelligence.toggle()
                return
            }
            let next = await Self.availability(target: subject.target, strategy: subject.strategy)
            guard !Task.isCancelled else { return }
            if next != availability || loadedSubject != subject {
                let hasNewModel = !isFirst && next.installed.contains { !availability.installed.contains($0) }
                withAnimation {
                    availability = next
                    loadedSubject = subject
                }
                if hasNewModel { settings.noteAutoTranslationModelInstalled() }
            }
            isFirst = false
            try? await clock.sleep(for: Self.pollingInterval)
        }
    }

    /// 翻訳先と同じ言語と、翻訳モードが対応していない言語は並べない。
    @concurrent
    private nonisolated static func availability(target: Locale.Language, strategy: TranslationStrategy) async -> Availability {
        let supported = await supportedLanguages(strategy: strategy)
            .map { (language: $0, item: Language(code: $0.minimalIdentifier, name: name(of: $0))) }
            .sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        var result = Availability(targets: supported.map(\.item))
        for (language, item) in supported where language.languageCode != target.languageCode {
            switch await status(source: language, target: target, strategy: strategy) {
            case .installed: result.installed.append(item)
            case .supported: result.downloadable.append(item)
            case .unsupported: break
            @unknown default: break
            }
        }
        return result
    }

    @concurrent
    private nonisolated static func supportedLanguages(strategy: TranslationStrategy) async -> [Locale.Language] {
        #if DEBUG
        if DebugStatusTranslator.isFake { return DebugStatusTranslator.fakeLanguages.map { Locale.Language(identifier: $0) } }
        #endif
        return await LanguageAvailability(preferredStrategy: TranslationSession.Strategy(strategy)).supportedLanguages
    }

    @concurrent
    private nonisolated static func status(source: Locale.Language, target: Locale.Language, strategy: TranslationStrategy) async -> LanguageAvailability.Status {
        #if DEBUG
        if DebugStatusTranslator.isFake {
            return strategy == .lowLatency && DebugStatusTranslator.fakeMissingLanguages.contains(source.minimalIdentifier) ? .supported : .installed
        }
        #endif
        return await LanguageAvailability(preferredStrategy: TranslationSession.Strategy(strategy)).status(from: source, to: target)
    }
}
