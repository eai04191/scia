import SwiftUI

/// Sciaが影響を受けたクライアントと、コードを書いたエージェント。コードや素材を取り込んだものではないので、ライセンスの画面とは分ける。
struct AcknowledgmentsView: View {
    /// 設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    let openProfile: @MainActor (_ acct: String) -> Void

    var body: some View {
        List {
            ForEach(AppInfo.acknowledgmentSections) { section in
                Section {
                    ForEach(section.items) { item in
                        AcknowledgmentRow(item: item, openProfile: openProfile)
                    }
                } header: {
                    Text(section.header)
                        .textCase(nil)
                }
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("謝辞")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgmentSection: Identifiable {
    let header: String
    let items: [AcknowledgmentItem]

    var id: String { header }
}

struct AcknowledgmentItem: Identifiable {
    let name: String
    var site: URL?
    var github: URL?
    /// Fediverseのアカウントのハンドル（`user@domain`）。
    var account: String?

    var id: String { name }
}

/// 名前を開くと、ウェブサイト、GitHub、アカウントの行を並べる。リンクがなければ名前だけを出す。
private struct AcknowledgmentRow: View {
    let item: AcknowledgmentItem
    let openProfile: @MainActor (_ acct: String) -> Void
    @State private var isExpanded = false

    var body: some View {
        if item.site == nil, item.github == nil, item.account == nil {
            Text(item.name)
        } else {
            DisclosureGroup(item.name, isExpanded: $isExpanded) {
                if let site = item.site {
                    Link("ウェブサイト", destination: site)
                }
                if let github = item.github {
                    Link("GitHub", destination: github)
                }
                if let account = item.account {
                    Button("アカウント") { openProfile(account) }
                }
            }
        }
    }
}
