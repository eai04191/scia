import SciaCore
import SwiftUI
import UIKit

/// 「通知の見た目」。通知のために足す部品の項目を、通知の行の上から下への並びで、部品ごとのセクションに置く。
/// メンションなどの投稿の部品は「投稿の見た目」で決めるので、ここには置かない。
struct NotificationAppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var confirmsReset = false

    var body: some View {
        Form {
            ForEach(NotificationAppearanceCatalog.groups) { group in
                Section(group.title) {
                    ForEach(group.values) { item in
                        // プレビューがないので、示す場所はない。
                        AppearanceValueRow(item: item, settings: settings, isFocused: false, onFocus: {}, onToggleFocus: {})
                    }
                }
            }
            Section {
                Button("すべて既定に戻す", role: .destructive) { confirmsReset = true }
                    .disabled(!settings.isNotificationAppearanceModified)
            } footer: {
                Text("メンションなどの投稿の見た目と、行の余白やアイコンの列の幅は「投稿の見た目」に従います。文字の大きさは、投稿の本文との差を保ちます。")
            }
        }
        .toolbar {
            // 数字のキーボードには確定のキーがないため、閉じて打った値を確定するボタンを置く。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .navigationTitle("通知の見た目")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("通知の見た目をすべて既定に戻しますか？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("既定に戻す", role: .destructive) {
                settings.resetNotificationAppearance()
            }
        }
    }
}
