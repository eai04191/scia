import SciaCore
import SwiftUI
import UIKit

/// 設定の「情報」。iPhoneの設定アプリの「一般」>「情報」と同じく、ビルドを灰色の値の行で並べ、接続の状態とライセンスの画面を開く。
struct AboutSettingsView: View {
    /// コピーしたことを知らせる表示を戻すまでの時計。
    let clock: any Clock<Duration>
    @State private var copied = false

    var body: some View {
        Form {
            // いろいろなブランチのビルドを入れ替えて試すときに、いま入っているのがどれか分かるようにする。
            // 違和感の報告などに貼れるよう、どの行をタップしても全部をまとめてコピーする
            Section {
                buildRow("バージョン", value: BuildInfo.current.version)
                buildRow("ブランチ", value: BuildInfo.current.branch)
                buildRow("commit", value: BuildInfo.current.commit)
                buildRow("ビルド日時", value: BuildInfo.current.builtAt.formatted(date: .numeric, time: .shortened))
            } footer: {
                if copied {
                    Text("コピーしました")
                }
            }
            Section {
                NavigationLink("接続の状態", value: SettingsPage.connection)
                NavigationLink("ライセンス", value: SettingsPage.licenses)
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("情報")
        .navigationBarTitleDisplayMode(.inline)
        .task(.withoutRequests, id: copied) {
            guard copied else { return }
            try? await clock.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func buildRow(_ title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = BuildInfo.current.text
            copied = true
        } label: {
            LabeledContent(title, value: value)
        }
        // 押すとコピーする行だが、ほかの行と同じ文字の色にそろえる
        .tint(.primary)
        .accessibilityHint(copied ? "コピーしました" : "タップでビルドの情報をコピーします")
    }
}
