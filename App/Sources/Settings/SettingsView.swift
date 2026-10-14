import SciaCore
import SwiftUI
import UIKit

/// 使う人が選ぶ設定の画面。
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("名前の表記", selection: $settings.statusNameStyle) {
                        Text("名前、@acct").tag(StatusNameStyle.nameAndAcct)
                        Text("名前").tag(StatusNameStyle.nameOnly)
                        Text("@acct").tag(StatusNameStyle.acctOnly)
                        Text("@acct、名前").tag(StatusNameStyle.acctAndName)
                    }
                    Picker("時刻の表記", selection: $settings.statusTimeStyle) {
                        Text("相対時刻").tag(StatusTimeStyle.relative)
                        Text("日時").tag(StatusTimeStyle.absolute)
                    }
                    Picker("アイコンの形", selection: $settings.avatarShape) {
                        Text("円").tag(AvatarShape.circle)
                        Text("角丸の四角").tag(AvatarShape.roundedSquare)
                    }
                    Toggle("アイコンのアニメーションを再生する", isOn: $settings.animatesAvatars)
                } header: {
                    Text("投稿の表示")
                } footer: {
                    Text("相対時刻では、1週間より前の投稿は日付で表示します。")
                }
                Section {
                    Toggle("モバイル通信で高画質のサムネイルを使う", isOn: $settings.usesOriginalThumbnailsOnExpensiveNetwork)
                } header: {
                    Text("画像")
                } footer: {
                    Text("オフにすると、モバイル通信とインターネット共有では、サーバーが縮小した画像を一覧に表示します。低データモードでは、この設定にかかわらず縮小した画像を表示します。")
                }
                Section {
                    Toggle("役に立たない代替テキストを無視する", isOn: $settings.ignoresUselessAltText)
                } header: {
                    Text("代替テキスト")
                } footer: {
                    Text("代替テキストが「undefined」や「Screenshot」だけのメディアを、代替テキストのないメディアとして扱います。空白だけの代替テキストは、この設定にかかわらず無視します。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

extension UIViewController {
    func presentSettings() {
        present(UIHostingController(rootView: SettingsView(settings: AppDependencies.settings)), animated: true)
    }
}
