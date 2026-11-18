import SciaCore
import SwiftUI

/// 2つのプリセットを比べる画面。決まりはdocs/preset.mdの「プリセットを比較」にある。
/// 上に「投稿の見た目」と同じ見本を固定し、セグメンテッドコントロールで比較元と比較先を切り替える。下の一覧には、読む値の違う項目だけを並べる。
struct PresetComparisonView: View {
    let settings: AppSettings
    @State private var base: PresetID
    @State private var target: PresetID
    /// 見本に描いている側。trueなら比較先。
    @State private var showsTarget = true
    @State private var baseSamples: AppearanceSamples
    @State private var targetSamples: AppearanceSamples
    @Environment(\.colorScheme) private var colorScheme

    private let tuning: TuningStore
    private let now: () -> Date

    init(settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: @escaping () -> Date = AppDependencies.now) {
        self.settings = settings
        self.tuning = tuning
        self.now = now
        let library = settings.store.library
        let base = PresetID.builtIn(.standard)
        let target = library.appPreset != base ? library.appPreset : .builtIn(.compact)
        _base = State(initialValue: base)
        _target = State(initialValue: target)
        _baseSamples = State(initialValue: AppearanceSamples(settings: settings.editing(base), tuning: tuning, now: now()))
        _targetSamples = State(initialValue: AppearanceSamples(settings: settings.editing(target), tuning: tuning, now: now()))
    }

    private var library: PresetLibrary { settings.store.observedLibrary }

    private var comparison: PresetComparison {
        PresetComparison(
            base: settings.editing(base),
            compared: settings.editing(target),
            languageName: Self.languageName,
            deviceLanguageName: Self.languageName(Locale.current.language.minimalIdentifier)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Picker(SettingsTexts.Presets.compare, selection: $showsTarget.animation(.smooth)) {
                    Text(library.name(of: base) ?? "").tag(false)
                    Text(library.name(of: target) ?? "").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                let samples = showsTarget ? targetSamples : baseSamples
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(colorScheme: colorScheme),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit
                )
                // 比べるプリセットを替えると見本のタイムラインが替わるので、置いたプレビューも作り直す。
                .id(ObjectIdentifier(samples.timeline))
                .transition(.opacity)
                Divider()
                Form {
                    Section {
                        presetPicker(SettingsTexts.Presets.compareBase, selection: $base)
                        presetPicker(SettingsTexts.Presets.compareTarget, selection: $target)
                    }
                    let sections = comparison.sections
                    if sections.isEmpty {
                        Section {
                            Text(SettingsTexts.Presets.noDifferences)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                PresetComparisonRow(row: row, baseName: library.name(of: base) ?? "", targetName: library.name(of: target) ?? "")
                            }
                        } header: {
                            PresetComparisonSectionHeader(section: section)
                        }
                    }
                }
            }
        }
        .navigationTitle(SettingsPage.presetComparison.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: base) { baseSamples = AppearanceSamples(settings: settings.editing(base), tuning: tuning, now: now()) }
        .onChange(of: target) { targetSamples = AppearanceSamples(settings: settings.editing(target), tuning: tuning, now: now()) }
        .onChange(of: library) { dropDeleted() }
    }

    private func presetPicker(_ title: String, selection: Binding<PresetID>) -> some View {
        Picker(title, selection: selection) {
            Section {
                ForEach(BuiltInPreset.allCases, id: \.self) { preset in
                    Label {
                        Text(preset.title)
                    } icon: {
                        // メニューは項目のアイコンを決まった大きさと色で描き、SwiftUIの`font`と`foregroundStyle`は効かないので、ほかの画面の鍵（`PresetNameLabel`）と同じ大きさと色を画像に持たせる。
                        Image(uiImage: Self.lockImage)
                    }
                    .tag(PresetID.builtIn(preset))
                }
            }
            if !library.userPresets.isEmpty {
                Section(SettingsTexts.Presets.userHeader) {
                    ForEach(library.userPresets, id: \.id) { preset in
                        Text(preset.name).tag(PresetID.user(preset.id))
                    }
                }
            }
        }
    }

    private static let lockImage = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))?
        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) ?? UIImage()

    /// 比べているプリセットがほかの窓で消されたら、標準に替える。
    private func dropDeleted() {
        if !library.contains(base) { base = .builtIn(.standard) }
        if !library.contains(target) { target = .builtIn(.standard) }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// 比べた1つの項目。名前の右に、比較元の値と比較先の値を矢印でつないで出す。並びは、押すと左右に並べた画面を開く。
struct PresetComparisonRow: View {
    let row: PresetComparison.Row
    let baseName: String
    let targetName: String

    var body: some View {
        switch (row.base, row.compared) {
        case (.text(let base), .text(let compared)):
            LabeledContent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ItemListText(list: base, textStyle: .body)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ItemListText(list: compared, textStyle: .body)
                        .foregroundStyle(.primary)
                }
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            } label: {
                Text(row.title)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.title)
            .accessibilityValue(SettingsTexts.Presets.comparedValues(base: base.spoken, compared: compared.spoken))
        case (.layout(let base), .layout(let compared)):
            NavigationLink {
                PresetLayoutComparisonView(title: row.detailTitle, columns: [(baseName, base), (targetName, compared)])
            } label: {
                LabeledContent(row.title, value: SettingsTexts.Presets.layoutDiffers)
            }
        default:
            preconditionFailure("比較元と比較先で読み方が違う")
        }
    }
}

/// 2つの並びを左右に並べる画面。区切り線と境目も並びのとおりに出し、非表示にした項目は薄くする。
private struct PresetLayoutComparisonView: View {
    let title: String
    let columns: [(name: String, lines: [PresetComparison.LayoutLine])]

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(columns[index].name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                        LayoutColumn(lines: columns[index].lines)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 1つの並び。区切り線で分けたまとまりを、角の丸い地に載せる。
private struct LayoutColumn: View {
    let lines: [PresetComparison.LayoutLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                line(lines[index])
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func line(_ line: PresetComparison.LayoutLine) -> some View {
        switch line {
        case .item(let title, let symbolName, let isVisible):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbolName)
                    .frame(width: 20)
                    .foregroundStyle(isVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(title)
                    .foregroundStyle(isVisible ? .primary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !isVisible {
                    Image(systemName: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isVisible ? "" : SettingsTexts.Presets.hidden)
        case .separator:
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 6)
                .accessibilityLabel(SettingsTexts.MenuLayout.separator)
        case .rowSeparator(let title):
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 2)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SettingsTexts.MenuLayout.rowSeparatorAccessibilityLabel)
            .accessibilityValue(title)
        case .more(let title):
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 2)
        }
    }
}

/// 比べた項目の節の見出し。設定の画面の階層の名前を、シェブロンでつなぐ。
struct PresetComparisonSectionHeader: View {
    let section: PresetComparison.Section

    var body: some View {
        // 文字より小さいフォントで描くと、記号がベースラインに寄って文字の中心より下に見えるので、見出しの文字の大きさのまま、記号の小さいスケールで描く。
        let chevron = Text(Image(systemName: "chevron.forward"))
        section.path.dropFirst().reduce(Text(verbatim: section.path.first ?? "")) { text, name in
            Text("\(text) \(chevron) \(name)")
        }
        .imageScale(.small)
        .accessibilityLabel(section.accessibilityTitle)
    }
}
