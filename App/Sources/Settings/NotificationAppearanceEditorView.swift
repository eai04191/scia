import SciaCore
import SwiftUI
import UIKit

/// 「通知の見た目」。上にプレビューを固定し、下に通知のために足す部品ごとの分類を、通知の行の上から下への並びで置く。
/// 分類を押すと、その分類の画面（`NotificationAppearanceGroupEditorView`）を重ねる。
/// メンションなどの投稿の部品は「投稿の見た目」で決めるので、ここには置かない。プレビューの決まりは「投稿の見た目」と同じで、docs/appearance.mdにある。
struct NotificationAppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var samples: NotificationAppearanceSamples
    /// 開いたときに重ねておく分類の画面。
    @State private var opened: AppearanceGroup.ID?
    @State private var confirmsReset = false
    /// すべて既定に戻した回数。戻すと値がまとめて変わるので、プレビューの高さを合わせ直す。
    @State private var resets = 0

    /// - Parameter group: 開いたときに重ねておく分類の画面。
    init(settings: AppSettings, opening group: AppearanceGroup.ID? = nil, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        _samples = State(initialValue: NotificationAppearanceSamples(settings: settings, tuning: tuning, now: now()))
        _opened = State(initialValue: group)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(groups: []),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit,
                    fitRevision: resets
                )
                Divider()
                Form {
                    Section {
                        ForEach(groups) { group in
                            NavigationLink {
                                NotificationAppearanceGroupEditorView(group: group, settings: settings)
                            } label: {
                                GroupLabel(title: group.title, isModified: group.values.contains(where: settings.isModified))
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
                            .disabled(!settings.isNotificationAppearanceModified)
                            .confirmationDialog(NotificationAppearanceCatalog.resetAllConfirmation, isPresented: $confirmsReset, titleVisibility: .visible) {
                                Button(AppearanceCatalog.resetTitle, role: .destructive) {
                                    settings.resetNotificationAppearance()
                                    resets += 1
                                }
                            }
                    } footer: {
                        Text(SettingsTexts.Appearance.notificationFooter)
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { id in
            if let group = groups.first(where: { $0.id == id }) {
                NotificationAppearanceGroupEditorView(group: group, settings: settings)
            }
        }
        .navigationTitle(SettingsPage.notificationAppearance.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groups: [AppearanceGroup] {
        NotificationAppearanceCatalog.groups
    }
}

/// 「通知の見た目」の、1つの分類の画面。上にその分類の見本を固定し、下にその分類の項目を置く。
/// 最後に触った項目にしか要らない見本は、触っている間だけプレビューに足す。
struct NotificationAppearanceGroupEditorView: View {
    let group: AppearanceGroup
    @Bindable var settings: AppSettings
    @State private var samples: NotificationAppearanceSamples
    /// 最後に触った項目。
    @State private var focused: AppearanceValue?

    init(group: AppearanceGroup, settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.group = group
        self.settings = settings
        _samples = State(initialValue: NotificationAppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(groups: [group.id], focus: focused),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit
                )
                Divider()
                Form {
                    ForEach(group.values) { item in
                        AppearanceValueRow(
                            item: item,
                            settings: settings,
                            isFocused: focused == item,
                            onFocus: { focused = item },
                            onToggleFocus: { focused = focused == item ? nil : item }
                        )
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
        .presetEditingSubtitle(settings)
    }
}

/// 「通知の見た目」のプレビューに並べる見本を、タイムライン（`TimelineViewController`）に並べて描く。何を並べるかは`NotificationAppearancePreviewSamples`にある。
/// 画像は通信しないよう、アプリのアイコンから作ったものと同梱した写真を使う。
@MainActor
struct NotificationAppearanceSamples {
    /// 見本を並べるタイムライン。見本を組むのにも、プレビューに置いて見せるのにも使う。1つの画面に1つずつ置く。
    let timeline: TimelineViewController
    private let samples: NotificationAppearancePreviewSamples

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        timeline = .appearancePreview(texts: .notifications, filterContext: .notifications, myAccountID: NotificationAppearancePreviewSamples.myAccountID, tuning: tuning, settings: settings)
        samples = NotificationAppearancePreviewSamples(now: now, sources: PreviewImages.notificationSampleSources())
    }

    /// プレビューのタイムラインに並べる見本。
    /// - Parameters:
    ///   - groups: 見本を出す分類。nilならすべての見本を返す。
    ///   - focus: 触っている項目。`groups`を渡したとき、その項目にしか要らない見本を足す。
    func entries(groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceValue? = nil) -> [TimelineEntry] {
        samples.notifications(groups: groups, focus: focus).map { .notification($0) }
    }

    /// 見本の行の中身。テストで、見本の部品の位置を測るのに使う。
    func configurations(groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceValue? = nil) -> [any UIContentConfiguration] {
        entries(groups: groups, focus: focus).compactMap { entry in
            guard case .notification(let notification) = entry else { return nil }
            return timeline.contentConfiguration(for: notification, base: .cell())
        }
    }
}
