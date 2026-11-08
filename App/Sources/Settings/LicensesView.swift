import SwiftUI

/// アプリに入れたり使ったりしている、ほかの人の作ったものと、そのライセンス。項目ごとに折りたたみ、開くと配布元と使い方を出す。
struct LicensesView: View {
    var body: some View {
        List {
            ForEach(AppInfo.licenses) { item in
                LicenseRow(item: item)
            }
        }
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseItem: Identifiable {
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
