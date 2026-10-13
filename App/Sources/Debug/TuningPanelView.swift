#if DEBUG
import SciaCore
import SwiftUI

/// チューニング項目を実行中に変更するパネル。タイムラインを見ながら調整できるよう、ハーフシートで出す。
struct TuningPanelView: View {
    let store: TuningStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("調整できる項目はまだありません", systemImage: "slider.horizontal.3")
                } else {
                    Form {
                        ForEach(store.items) { item in
                            row(for: item)
                        }
                    }
                }
            }
            .navigationTitle("チューニング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("既定値に戻す", role: .destructive) { store.resetAll() }
                        .disabled(store.items.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
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
