#if DEBUG
import SciaCore
import SwiftUI

/// チューニング項目を実行中に変更するパネル。タイムラインを見ながら調整できるよう、ハーフシートで出す。
struct TuningPanelView: View {
    let store: TuningStore
    @Environment(\.dismiss) private var dismiss
    /// 開いているカテゴリのid。調整のたびにパネルを開き直すので、開き直しても前の状態で出す。
    @AppStorage("tuningPanel.expandedSections") private var expandedSectionIDs = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("調整できる項目はまだありません", systemImage: "slider.horizontal.3")
                } else {
                    Form {
                        ForEach(store.sections) { section in
                            Section {
                                DisclosureGroup(isExpanded: isExpanded(section)) {
                                    ForEach(section.items) { item in
                                        row(for: item)
                                    }
                                    Button("このカテゴリを既定値に戻す", role: .destructive) { store.reset(section) }
                                        .disabled(!store.isModified(section))
                                } label: {
                                    LabeledContent(section.title) {
                                        if store.isModified(section) {
                                            Text("変更あり")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listSectionSpacing(.compact)
                }
            }
            .navigationTitle("チューニング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("すべて戻す", role: .destructive) { store.resetAll() }
                        .disabled(store.items.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func isExpanded(_ section: TuningSection) -> Binding<Bool> {
        Binding(
            get: { expandedSectionIDs.split(separator: ",").contains(Substring(section.id)) },
            set: { isExpanded in
                var ids = expandedSectionIDs.split(separator: ",").map(String.init).filter { $0 != section.id }
                if isExpanded {
                    ids.append(section.id)
                }
                expandedSectionIDs = ids.joined(separator: ",")
            }
        )
    }

    @ViewBuilder
    private func row(for item: TuningItem) -> some View {
        switch item {
        case .number(let tuning):
            let value = Binding(get: { store.value(of: tuning) }, set: { store.setValue($0, for: tuning) })
            VStack(alignment: .leading) {
                LabeledContent(tuning.title) {
                    Text(value.wrappedValue, format: .number.precision(.fractionLength(0...3)))
                        .monospacedDigit()
                }
                Slider(value: value, in: tuning.range, step: tuning.step)
            }
        case .toggle(let tuning):
            Toggle(tuning.title, isOn: Binding(get: { store.value(of: tuning) }, set: { store.setValue($0, for: tuning) }))
        }
    }
}

extension UIViewController {
    func presentTuningPanel() {
        let controller = UIHostingController(rootView: TuningPanelView(store: AppDependencies.tuning))
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }
}
#endif
