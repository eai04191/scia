import SwiftUI

/// Sciaが影響を受けたクライアントと、コードを書いたエージェント。コードや素材を取り込んだものではないので、ライセンスの画面とは分ける。
struct AcknowledgmentsView: View {
    /// 設定の画面を閉じて、ハンドルの人のプロフィールを開く。
    let openProfile: @MainActor (_ acct: String) -> Void

    var body: some View {
        List {
            Section {
                ForEach(Self.clients) { item in
                    AcknowledgmentRow(item: item, openProfile: openProfile)
                }
            } header: {
                Text("Sciaは次のクライアントから多くの影響を受けています")
                    .textCase(nil)
            }
            Section {
                ForEach(Self.agents) { item in
                    AcknowledgmentRow(item: item, openProfile: openProfile)
                }
            } header: {
                Text("Sciaのコードはすべて次のエージェントが書いています")
                    .textCase(nil)
            }
        }
        .topEdgeEffectHiddenOnMac()
        .navigationTitle("謝辞")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let clients: [AcknowledgmentItem] = [
        AcknowledgmentItem(name: "SubwayTooter", github: URL(string: "https://github.com/tateisu/SubwayTooter"), account: "SubwayTooter@mastodon.juggler.jp"),
        AcknowledgmentItem(name: "Metatext", site: URL(string: "https://metabolist.org/"), github: URL(string: "https://github.com/metabolist/metatext")),
        AcknowledgmentItem(name: "iMast", site: URL(string: "https://cinderella-project.github.io/iMast/"), github: URL(string: "https://github.com/cinderella-project/iMast"), account: "imast_ios@mstdn.rinsuki.net"),
        AcknowledgmentItem(name: "DAWN", site: URL(string: "https://noppe.dev/dawn/")),
        AcknowledgmentItem(name: "Mona", account: "MonaApp@mastodon.social"),
        // 提供を終えていて、今の公式のページがないので、名前だけ載せる。
        AcknowledgmentItem(name: "twitcle plus"),
    ]

    private static let agents: [AcknowledgmentItem] = [
        AcknowledgmentItem(name: "Claude Code", site: URL(string: "https://claude.com/product/claude-code")),
        AcknowledgmentItem(name: "Codex", site: URL(string: "https://openai.com/codex/")),
    ]
}

private struct AcknowledgmentItem: Identifiable {
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
