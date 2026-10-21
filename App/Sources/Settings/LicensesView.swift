import SwiftUI

/// アプリに入れたり使ったりしている、ほかの人の作ったものと、そのライセンス。項目ごとに折り畳み、開くと出どころと使い方を出す。
struct LicensesView: View {
    var body: some View {
        List {
            ForEach(Self.items) { item in
                LicenseRow(item: item)
            }
        }
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let items: [LicenseItem] = [
        LicenseItem(
            name: "Twemoji",
            license: "CC BY 4.0",
            copyright: "Copyright Twitter, Inc and other contributors",
            usage: "設定で「Twemoji」を選んだときの絵文字の絵。SVGをカラーフォント（TrueType、COLR形式）に変換して使っています。",
            source: URL(string: "https://github.com/jdecked/twemoji"),
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")
        ),
        LicenseItem(
            name: "FediDB",
            license: "CC BY 4.0",
            copyright: "FediDB",
            usage: "ログイン画面で出すサーバーの候補。FediDBのサーバーのデータセットから、Mastodonとその派生のサーバーを選び、月間のアクティブユーザーが多い順に並べて使っています。",
            source: URL(string: "https://fedidb.com"),
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")
        ),
    ]
}

private struct LicenseItem: Identifiable {
    let name: String
    let license: String
    let copyright: String
    let usage: String
    let source: URL?
    let licenseURL: URL?

    var id: String { name }
}

private struct LicenseRow: View {
    let item: LicenseItem
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.copyright)
                Text(item.usage)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            if let source = item.source {
                Link("配布元", destination: source)
            }
            if let licenseURL = item.licenseURL {
                Link("ライセンス（\(item.license)）", destination: licenseURL)
            }
        } label: {
            LabeledContent(item.name, value: item.license)
        }
    }
}
