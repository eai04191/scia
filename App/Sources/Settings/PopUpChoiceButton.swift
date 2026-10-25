import SwiftUI
import UIKit

/// 選択肢をメニューで選ぶ、UIKit標準のポップアップボタン。メニューを開いたことを`onOpen`で知らせる。
/// SwiftUIのPickerのメニューは中のボタンが押下を受けるため、開いたことを外から拾えない。
struct PopUpChoiceButton<Value: Hashable>: UIViewRepresentable {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.onOpen?() }, for: .menuActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onOpen = onOpen
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.title, state: option.value == selection ? .on : .off) { _ in
                selection = option.value
            }
        })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator {
        var onOpen: (() -> Void)?
    }
}

/// 名前と、選んでいる値のポップアップボタンを並べた行。
struct PopUpChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// メニューを開いたときに呼ぶ。
    let onOpen: () -> Void
    /// ボタンのほかの場所をタップしたときに呼ぶ。
    let onTapTitle: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            PopUpChoiceButton(selection: $selection, options: options, onOpen: onOpen)
                .accessibilityLabel(title)
        }
        // 数値の行と同じく、行のどこをタップしても示す。ボタンの上のタップはボタンが受ける。
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapTitle)
    }
}

/// 名前とスイッチを並べた行。スイッチのほかの場所をタップしても切り替えず、`onTapTitle`を呼ぶ。
struct TitledToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let onTapTitle: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
        // 数値の行と同じく、行のどこをタップしても示す。スイッチの上のタップはスイッチが受ける。
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapTitle)
    }
}
