import SciaCore
import SwiftUI
import UIKit

/// 「投稿の見た目」。上にプレビューを固定し、下に投稿の部品ごとの分類を、投稿の上から下への並びで置く。
/// 分類を押すと、その分類の画面（`AppearanceGroupEditorView`）を重ねる。決まりはdocs/appearance.mdにある。
struct AppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var samples: AppearanceSamples
    /// 開いたときに重ねておく分類の画面。
    @State private var opened: AppearanceGroup.ID?
    @State private var confirmsReset = false
    /// すべて既定に戻した回数。戻すと値がまとめて変わるので、プレビューの高さを合わせ直す。
    @State private var resets = 0
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameter group: 開いたときに重ねておく分類の画面。
    init(settings: AppSettings, opening group: AppearanceGroup.ID? = nil, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        _samples = State(initialValue: AppearanceSamples(settings: settings, tuning: tuning, now: now()))
        _opened = State(initialValue: group)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(colorScheme: colorScheme, groups: []),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit,
                    fitRevision: resets
                )
                Divider()
                Form {
                    Section {
                        // どの分類の「〜を表示」にも効くので、分類の中には置かない。
                        Toggle(isOn: $settings.appearance.revealsAllPartsInThread) {
                            // インジケーターは名前の幅に足さない。足すと、変えていなくても名前が2行に折り返すため。
                            Text(SettingsTexts.Appearance.revealsAllPartsInThread)
                                .overlay(alignment: .trailing) {
                                    ModifiedIndicator(isModified: settings.isRevealsAllPartsInThreadModified)
                                        .offset(x: 10)
                                }
                        }
                        .contextMenu {
                            Button(SettingsTexts.Appearance.resetItem, systemImage: "arrow.uturn.backward") {
                                settings.resetRevealsAllPartsInThread()
                            }
                            .disabled(!settings.isRevealsAllPartsInThreadModified)
                        }
                    } footer: {
                        Text(SettingsTexts.Appearance.revealsAllPartsInThreadFooter)
                    }
                    Section {
                        ForEach(groups) { group in
                            NavigationLink {
                                AppearanceGroupEditorView(group: group, settings: settings)
                            } label: {
                                GroupLabel(title: group.title, isModified: settings.isAppearanceGroupModified(group))
                            }
                        }
                    }
                    Section {
                        // 確認のポップオーバーを行の真ん中から出すため、ボタンを行の幅に広げる。
                        Button(role: .destructive) {
                            confirmsReset = true
                        } label: {
                            Text(AppearanceCatalog.resetAllTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                            .disabled(!settings.isAppearanceModified)
                            .confirmationDialog(AppearanceCatalog.resetAllConfirmation, isPresented: $confirmsReset, titleVisibility: .visible) {
                                Button(AppearanceCatalog.resetTitle, role: .destructive) {
                                    settings.resetAppearance()
                                    resets += 1
                                }
                            }
                    } footer: {
                        Text(SettingsTexts.Appearance.footer)
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { id in
            if let group = groups.first(where: { $0.id == id }) {
                AppearanceGroupEditorView(group: group, settings: settings)
            }
        }
        .navigationTitle(SettingsPage.appearance.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) { await samples.showAnimatedAvatarWhenReady(colorScheme: colorScheme, groups: []) }
    }

    private var groups: [AppearanceGroup] {
        AppearanceCatalog.groups
    }
}

/// 「投稿の見た目」の、1つの分類の画面。上にその分類の見本を固定し、下にその分類の項目を置く。
/// 最後に触った項目にしか要らない見本は、触っている間だけプレビューに足す。
struct AppearanceGroupEditorView: View {
    let group: AppearanceGroup
    @Bindable var settings: AppSettings
    @State private var samples: AppearanceSamples
    /// 最後に触った項目。
    @State private var focused: AppearanceFocus?
    @Environment(\.colorScheme) private var colorScheme

    init(group: AppearanceGroup, settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.group = group
        self.settings = settings
        _samples = State(initialValue: AppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(colorScheme: previewColorScheme, groups: [group.id], focus: focused),
                    interfaceStyle: focused?.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified,
                    heightLimit: geometry.size.height * Self.previewHeightLimit
                )
                Divider()
                Form {
                    // 選んで決める項目のない分類では、中身のないセクションは描かれない。
                    Section {
                        ForEach(choices, id: \.self) { choice in
                            choiceRow(choice)
                        }
                    }
                    Section {
                        ForEach(group.values) { item in
                            AppearanceValueRow(
                                item: item,
                                settings: settings,
                                isFocused: focused == .value(item),
                                onFocus: { focused = .value(item) },
                                onToggleFocus: { toggleFocus(.value(item)) }
                            )
                            .disabled(!AppearanceCatalog.isUsed(item, in: settings.appearance))
                        }
                    }
                }
            }
        }
        .toolbar {
            // 数字のキーボードには確定のキーがないため、閉じて打った値を確定するボタンを置く。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(SettingsTexts.done) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests) { await samples.showAnimatedAvatarWhenReady(colorScheme: previewColorScheme, groups: [group.id], focus: focused) }
        .presetEditingSubtitle(settings)
    }

    /// 見本の高さの上限。画面の高さに対する割合。
    static let previewHeightLimit: CGFloat = 0.42

    /// 見本を描く外観。外観ごとにしか効かない項目を触っている間は、その外観で描く。端末と違う外観の項目では、値を変えても見た目が変わらないため。
    private var previewColorScheme: ColorScheme {
        focused?.colorScheme ?? colorScheme
    }

    /// 項目の名前をタップしたとき、その項目を触っている項目にする。触っている項目なら、やめる。
    private func toggleFocus(_ focus: AppearanceFocus) {
        focused = focused == focus ? nil : focus
    }

    /// 数値ではなく選んで決める項目。その部品の項目の先頭に置く。何を、どの順で、どんな名前で並べるかは`AppearanceChoice`にある。
    private var choices: [AppearanceChoice] {
        AppearanceChoice.choices(inGroup: group.id).filter { $0 != .drawsReactionGlowInHDR || ReactionGlowView.mayDrawInHDR }
    }

    @ViewBuilder
    private func choiceRow(_ choice: AppearanceChoice) -> some View {
        switch choice.control {
        case .toggle(let keyPath):
            // スイッチは押すとすぐ切り替わるので、切り替えたときに触っている項目にする。メニューで選ぶ項目は、メニューを開いたときにする。
            let isOn = Binding {
                settings[keyPath: keyPath]
            } set: { newValue in
                guard settings[keyPath: keyPath] != newValue else { return }
                settings[keyPath: keyPath] = newValue
                focused = .choice(choice)
            }
            TitledToggleRow(title: choice.title, isOn: isOn, isModified: settings.isModified(choice)) { toggleFocus(.choice(choice)) }
                .contextMenu { resetButton(choice) }
                .disabled(!choice.isEnabled(in: settings.appearance))
        case .options(let options):
            PopUpChoiceRow(
                title: choice.title,
                selection: Binding { options.selectedIndex(settings) } set: { options.select($0, settings) },
                options: options.titles.enumerated().map { (value: $0.offset, title: $0.element) },
                isModified: settings.isModified(choice),
                onOpen: { focus(choice) },
                onTapTitle: { toggleFocus(.choice(choice)) }
            )
            .contextMenu { resetButton(choice) }
            .disabled(!choice.isEnabled(in: settings.appearance))
        }
    }

    private func resetButton(_ choice: AppearanceChoice) -> some View {
        Button(SettingsTexts.Appearance.resetItem, systemImage: "arrow.uturn.backward") {
            settings.reset(choice)
            focused = .choice(choice)
        }
        .disabled(!settings.isModified(choice))
    }

    /// 選択肢のメニューを開いたときに、その場所を示す。選んで閉じても示したままにする。
    private func focus(_ choice: AppearanceChoice) {
        focused = .choice(choice)
    }
}

extension AppearanceFocus {
    /// この項目が効く外観。どちらの外観でも効く項目はnil。
    var colorScheme: ColorScheme? {
        switch scheme {
        case .light: .light
        case .dark: .dark
        case nil: nil
        }
    }
}

/// 部品の見出し。既定値から変えた項目があれば、印を添える。
struct GroupLabel: View {
    let title: String
    let isModified: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if isModified {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(SettingsTexts.Appearance.modified)
            }
        }
    }
}

/// 数値の項目の1行。値はステッパーで1刻みずつ変える。スライダーより、1ptの違いを合わせやすいため。
struct AppearanceValueRow: View {
    let item: AppearanceValue
    @Bindable var settings: AppSettings
    let isFocused: Bool
    /// 値を変えたときに呼ぶ。変えた項目は示し続ける。
    let onFocus: () -> Void
    /// 名前をタップしたときに呼ぶ。示していれば、示すのをやめる。
    let onToggleFocus: () -> Void
    /// 値を入力している。入力している間は、打っている文字を値の欄に出す。
    @FocusState private var isEditing: Bool
    @State private var draft = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                    ModifiedIndicator(isModified: settings.isModified(item))
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // ＋−では遠い値まで届きにくいので、値の欄に数字を直接打てるようにする。
            HStack(spacing: 2) {
                TextField(item.title, text: Binding { isEditing ? draft : numberText } set: { draft = $0 })
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 52)
                    .focused($isEditing)
                    .accessibilityLabel(item.title)
                    .onChange(of: isEditing) { _, editing in
                        if editing {
                            draft = numberText
                            onFocus()
                        } else {
                            commit()
                        }
                    }
                if let unitText {
                    Text(unitText)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(item.title, value: value, in: item.range, step: item.step)
                .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleFocus)
        .contextMenu {
            Button(SettingsTexts.Appearance.resetItem, systemImage: "arrow.uturn.backward") {
                settings.reset([item])
                onFocus()
            }
            .disabled(!settings.isModified(item))
        }
    }

    private var value: Binding<Double> {
        Binding {
            settings.value(of: item)
        } set: { newValue in
            settings.setValue(newValue, for: item)
            onFocus()
        }
    }

    private var typography: PostTypography {
        PostTypography(settings: settings)
    }

    private var role: PostTypography.Role? {
        PostTypography.Role.allCases.first { $0.setting == item }
    }

    /// 値の欄に出す数。文字の大きさは、本文との差ではなく、実際の大きさで見せる。
    private var numberText: String {
        if let role {
            return Self.format(typography.standardPointSize(role))
        }
        let value = settings.value(of: item)
        return item.unit == .ratio ? String(format: "%.2f", value) : Self.format(value)
    }

    private var unitText: String? {
        item.unit.title
    }

    /// 打った数を値にする。文字の大きさは実際の大きさで打つので、本文との差に直す。範囲の外は範囲に収め、数でなければ元のままにする。
    private func commit() {
        guard let number = Double(draft.replacingOccurrences(of: ",", with: ".")) else { return }
        let newValue = role.map { Double(typography.offset(for: $0, standardPointSize: CGFloat(number))) } ?? number
        // 打ち直さずに閉じたときは、何もしない。名前のタップで示すのをやめたのを、閉じたことで示し直さないため。
        guard newValue != settings.value(of: item) else { return }
        settings.setValue(newValue, for: item)
        onFocus()
    }

    private var note: String? {
        item.note(for: settings.value(of: item))
    }

    private static func format(_ value: Double) -> String {
        AppearanceValue.numberText(value)
    }

    private static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }
}

/// 「投稿の見た目」のプレビューに並べる見本を、タイムライン（`TimelineViewController`）に並べて描く。何を並べるかは`AppearancePreviewSamples`にある。
/// 画像は通信しないよう、アプリのアイコンから作ったものと同梱した写真を使う。
@MainActor
@Observable
final class AppearanceSamples {
    /// 見本を並べるタイムライン。見本を組むのにも、プレビューに置いて見せるのにも使う。1つの画面に1つずつ置く。
    let timeline: TimelineViewController
    private let settings: AppSettings
    private let tuning: TuningStore
    private let now: Date
    private var samples: AppearancePreviewSamples
    private var hasAnimatedAvatar: Bool
    /// アニメーション版に替える前に、その画像を読み込み終えるのを待つ長さの上限。読めないときも、静止画のまま止まらないようにする。
    private static let animatedAvatarLoadWait: Duration = .seconds(1)

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        self.settings = settings
        self.tuning = tuning
        self.now = now
        timeline = .appearancePreview(texts: .home, filterContext: .home, myAccountID: AppearancePreviewSamples.myAccountID, tuning: tuning, settings: settings)
        let sources = PreviewImages.sampleSources()
        hasAnimatedAvatar = sources.animatedAvatar != nil
        samples = AppearancePreviewSamples(now: now, sources: sources)
        for status in samples.spoilerStatuses {
            timeline.toggleSpoiler(of: status)
        }
    }

    /// 見本のアイコンと絵文字のアニメーション版（`PreviewImages.animatedAvatarURL()`）を作り終えたら、静止画から替える。
    /// 替える前に、替えたあとのアイコンと絵文字の画像を読み込んでおく。読み込む前に替えると、届くまでの間、アイコンが灰色に、絵文字が空白になるため。
    /// アイコンは、引数の見本（`entries`と同じ）に出す分だけを読む。出さない見本のアイコンまで読むと、大きさの設定によっては、使わない大きな画像でアイコンのキャッシュを埋めるため。
    func showAnimatedAvatarWhenReady(colorScheme: ColorScheme, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil) async {
        guard !hasAnimatedAvatar, let animated = await PreviewImages.animatedAvatarWhenReady(), !Task.isCancelled else { return }
        let next = AppearancePreviewSamples(now: now, sources: PreviewImages.sampleSources())
        let elapsed = stopwatch(on: AppDependencies.clock)
        await timeline.waitForAvatars(of: { next.statuses(isDark: colorScheme == .dark, groups: groups, focus: focus, appearance: settings.appearance).map { .status($0) } }, within: Self.animatedAvatarLoadWait)
        await Self.loadEmoji(animated, within: Self.animatedAvatarLoadWait - elapsed())
        guard !Task.isCancelled else { return }
        hasAnimatedAvatar = true
        crossfade { samples = next }
    }

    /// 替える前の見本の画像を重ね、替えたあとに薄くして消す。
    /// カスタム絵文字は端末の時刻に合わせたコマから再生する（`AnimatedEmojiOverlay.frameAnimation`）ので、静止画から替えた瞬間に、1周の途中の色へ一コマで飛ぶため。
    /// 重ねる画像はコレクションビューの中に置き、フェードの途中にスクロールしても行と一緒に動かす。
    private func crossfade(_ change: () -> Void) {
        let duration = tuning.value(of: TuningCatalog.appearancePreviewAnimatedAvatarFadeDuration)
        let collectionView = timeline.collectionView
        guard duration > 0, collectionView.window != nil, let cover = collectionView.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        cover.frame = collectionView.bounds
        cover.isUserInteractionEnabled = false
        collectionView.addSubview(cover)
        change()
        UIView.animateSmoothly(duration: duration) {
            cover.alpha = 0
        } completion: {
            cover.removeFromSuperview()
        }
    }

    /// 絵文字の静止画とアニメーションを読み終えるか、`timeout`が過ぎるまで待つ。
    private static func loadEmoji(_ url: URL, within timeout: Duration) async {
        let store = AppDependencies.emojiImages
        func isLoaded() -> Bool {
            store.image(for: url) != nil && store.hasFinishedLoadingAnimation(for: url)
        }
        _ = store.animation(for: url)
        guard !isLoaded(), timeout > .zero else { return }
        let (loads, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let owner = NSObject()
        store.addListener(owner: owner) { urls in
            if urls.contains(url) { continuation.yield() }
        }
        let clock = AppDependencies.clock
        let timer = Task(.withoutRequests) {
            try? await clock.sleep(for: timeout)
            continuation.finish()
        }
        defer {
            timer.cancel()
            withExtendedLifetime(owner) {}
        }
        for await _ in loads where isLoaded() {
            return
        }
    }

    /// プレビューのタイムラインに並べる見本。
    /// - Parameters:
    ///   - groups: 見本を出す分類。nilならすべての見本を返す。
    ///   - focus: 触っている項目。`groups`を渡したとき、その項目にしか要らない見本を足す。
    func entries(colorScheme: ColorScheme, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil) -> [TimelineEntry] {
        timeline.showsActionBarInPreview = AppearancePreviewSamples.showsActionBar(inGroups: groups)
        return samples.statuses(isDark: colorScheme == .dark, groups: groups, focus: focus, appearance: settings.appearance).map { .status($0) }
    }

    /// 見本の行の中身。タイムラインに並べたときと同じく、返信でつながった隣の行と線でつなぐ。テストで、見本の部品の位置を測るのに使う。
    /// - Parameter revision: 描き直しのきっかけ。中身は使わない。
    func configurations(colorScheme: ColorScheme, revision _: Int, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil) -> [PostContentConfiguration] {
        let entries = entries(colorScheme: colorScheme, groups: groups, focus: focus)
        let connections = ReplyConnection.connections(in: entries)
        return entries.compactMap { entry in
            guard case .status(let status) = entry else { return nil }
            var configuration = timeline.contentConfiguration(for: status, base: .cell())
            configuration.replyConnection = connections[entry.id] ?? ReplyConnection()
            return configuration
        }
    }
}
