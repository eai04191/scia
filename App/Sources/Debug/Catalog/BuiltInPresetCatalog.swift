import SciaCore
import UIKit

/// 組み込みのプリセットを調整するために、アプリの既定値（標準）から変えた値の一覧と、同じ投稿を標準と各プリセットで組んだものを並べる。
/// 値はアプリの設定を変えずに、カタログ用の保存先でプリセットを読む設定から読む。
enum BuiltInPresetCatalog {
    private typealias Fixtures = CatalogFixtures

    @MainActor
    static func states() -> [CatalogState] {
        let suiteName = "net.mizle.scia.catalog.builtInPresets"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("カタログのUserDefaultsを作れない")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettings(defaults: defaults)
        let standard = store.editing(.builtIn(.standard))
        let presets = BuiltInPreset.allCases.filter { $0 != .standard }

        let tables = presets.map { preset in
            CatalogState(title: "\(preset.title)で変えた値（標準 → \(preset.title)）") {
                CatalogFrame.bordered(differenceList(store.editing(.builtIn(preset)).differences(from: standard)))
            }
        }

        let timelines = Dictionary(uniqueKeysWithValues: BuiltInPreset.allCases.map { preset in
            (preset, TimelineViewController(texts: .home, settings: store.editing(.builtIn(preset)), refresh: {}))
        })
        let posts = samplePosts()
        let rows = posts.flatMap { title, status in
            BuiltInPreset.allCases.map { preset in
                CatalogState(title: "\(title)・\(preset.title)") {
                    guard let timeline = timelines[preset] else { preconditionFailure("\(preset)のタイムラインがない") }
                    return CatalogFrame.post { timeline.contentConfiguration(for: status, base: .cell()) }
                }
            }
        }
        return tables + rows
    }

    /// 項目の名前の下に、標準の値と、プリセットの値を矢印でつないで並べる。
    @MainActor
    private static func differenceList(_ differences: [PresetDifference]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        for difference in differences {
            let title = UILabel()
            title.text = difference.title
            title.font = .preferredFont(forTextStyle: .subheadline)
            title.numberOfLines = 0
            let values = UILabel()
            values.text = "\(difference.base) → \(difference.compared)"
            values.font = .preferredFont(forTextStyle: .headline)
            values.numberOfLines = 0
            let row = UIStackView(arrangedSubviews: [title, values])
            row.axis = .vertical
            row.spacing = 2
            stack.addArrangedSubview(row)
        }
        if differences.isEmpty {
            let label = UILabel()
            label.text = "標準と同じ"
            label.textColor = .secondaryLabel
            stack.addArrangedSubview(label)
        }
        return stack
    }

    /// プリセットが変える余白、文字、アイコン、メディア、アクションバーが表れる投稿。
    @MainActor
    private static func samplePosts() -> [(String, Status)] {
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange]
        func images(_ count: Int) -> [MediaAttachment] {
            (0..<count).map { Fixtures.attachment("\($0)", width: 1_200, height: 900, color: colors[$0 % colors.count], label: "\($0 + 1)") }
        }
        return [
            ("本文だけ", PostRowCatalog.status(content: "<p>本文だけの投稿。余白、名前と本文のあいだ、文字の大きさを見比べる。</p>")),
            ("画像1つ", PostRowCatalog.status(content: "<p>画像を1つ添付した投稿。</p>", media: images(1))),
            ("縦長の画像", PostRowCatalog.status(content: "<p>縦長の画像。</p>", media: [Fixtures.attachment("tall", width: 600, height: 1_800, color: .systemTeal, label: "縦長")])),
            ("画像3つ、本文が長い", PostRowCatalog.status(content: "<p>" + String(repeating: "本文が長く、何行にもわたって折り返すことを確かめる文。", count: 4) + "</p>", media: images(3))),
            ("ブーストされた返信", PostRowCatalog.status(content: "<p>ブーストされた返信。</p>", rebloggedBy: PostRowCatalog.booster, replyingTo: PostRowCatalog.booster)),
        ]
    }
}

