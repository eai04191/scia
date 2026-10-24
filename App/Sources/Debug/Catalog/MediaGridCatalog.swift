#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 一覧の行に並べる添付ファイルのサムネイル（`MediaGridView`）の状態。
/// 並べ方と覆いは、一覧と同じく`TimelineViewController.mediaContent(for:)`で投稿から組み立てる。説明にならない代替テキストを除くかは、アプリの設定に従う。
enum MediaGridCatalog {
    private typealias Fixtures = CatalogFixtures

    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "1枚（横長 16:9）") { grid([Fixtures.attachment("a", width: 1_600, height: 900, color: .systemGreen)]) },
            CatalogState(title: "1枚（縦長 9:16、高さの上限で切る）") { grid([Fixtures.attachment("a", width: 900, height: 1_600)]) },
            CatalogState(title: "1枚（パノラマ 5:1、左右を切る）") { grid([Fixtures.attachment("a", width: 2_500, height: 500, color: .systemPurple)]) },
            CatalogState(title: "2枚") { grid(images(2)) },
            CatalogState(title: "3枚") { grid(images(3)) },
            CatalogState(title: "4枚") { grid(images(4)) },
            CatalogState(title: "6枚（4枚目に残りの数）") { grid(images(6)) },
            CatalogState(title: "閲覧注意で覆う") { grid(images(2), sensitive: true) },
            CatalogState(title: "メニューから隠した") { grid(images(2), hidden: true) },
            CatalogState(title: "フィルターで覆う") { grid(images(2), filterTitle: "ネタバレ") },
            CatalogState(title: "フィルターで覆う（名前が長い）") { grid(images(2), filterTitle: String(repeating: "長いフィルターの名前", count: 4)) },
            CatalogState(title: "代替テキスト（ALTあり、説明にならない「Screenshot」。設定で無視していれば右にALTは出ない）") {
                grid([
                    Fixtures.attachment("a", width: 1_200, height: 1_200, color: .systemGreen, description: "緑の地に白い格子"),
                    Fixtures.attachment("b", width: 1_200, height: 1_200, color: .systemOrange, description: "Screenshot"),
                ])
            },
            CatalogState(title: "種類のアイコン（動画、GIF、音声、表示できないファイル）") {
                grid([
                    Fixtures.attachment("a", type: .video, width: 1_280, height: 720, color: .systemTeal),
                    Fixtures.attachment("b", type: .gifv, width: 720, height: 720, color: .systemIndigo),
                    Fixtures.attachment("c", type: .audio, width: 0, height: 0, hasPreview: false),
                    Fixtures.attachment("d", type: .unknown("unknown"), width: 0, height: 0, hasPreview: false),
                ])
            },
            CatalogState(title: "再生アイコン（幅160pt、投稿欄の64pt、編集履歴の44pt、通知の再掲の既定の40ptと最小の24ptの正方形。短い辺に比例させ、チューニングの上限と下限で止める）") {
                tiles(Fixtures.attachment("a", type: .video, width: 1_280, height: 720, color: .systemTeal), widths: [160, 64, 44, 40, 24], square: true)
            },
            CatalogState(title: "バッジ（ALTとGIF。幅160pt、投稿欄の64pt、通知の再掲の既定の40ptと最小の24ptのタイル。入らなければ頭の1文字にし、余白、文字の順に詰める）") {
                tiles(Fixtures.attachment("a", type: .gifv, width: 1_200, height: 900, color: .systemIndigo, description: "動くGIF"))
            },
            CatalogState(title: "バッジ（ALTとGIFとHDR。HDRは、ビューアの設定がビューア以外より明るいときだけ出る）") {
                tiles(Fixtures.attachment("a", type: .gifv, width: 1_200, height: 900, color: .systemIndigo, description: "動くGIF", hdr: true))
            },
            CatalogState(title: "バッジ（文字の大きさを最大にしたとき。バッジの文字は上限で止まる）") {
                tiles(Fixtures.attachment("a", type: .gifv, width: 1_200, height: 900, color: .systemIndigo, description: "動くGIF", hdr: true), contentSize: .accessibilityExtraExtraExtraLarge)
            },
            CatalogState(title: "読み込み中（ぼかしの下地あり、なし）") {
                grid(
                    [
                        Fixtures.attachment("a", width: 1_200, height: 1_200, blurhash: Fixtures.blurhash),
                        Fixtures.attachment("b", width: 1_200, height: 1_200),
                    ],
                    store: Fixtures.pendingMediaImages
                )
            },
            CatalogState(title: "読み込めない（ぼかしの下地あり、なし）") {
                grid(
                    [
                        Fixtures.attachment("a", width: 1_200, height: 1_200, blurhash: Fixtures.blurhash),
                        Fixtures.attachment("b", width: 1_200, height: 1_200),
                    ],
                    store: Fixtures.failingMediaImages
                )
            },
        ]
    }

    /// 色で見分ける。番号を描くと、最後のタイルに重ねる残りの数と重なって読みにくい。
    private static func images(_ count: Int) -> [MediaAttachment] {
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        return (0..<count).map { index in
            Fixtures.attachment("\(index)", width: 1_200, height: 900, color: colors[index % colors.count])
        }
    }

    /// 同じ添付ファイルのタイルを、幅を変えて並べる。一覧の並べ方では狭いタイルが出にくいため、バッジが幅に入らないときの形を直接見る。
    /// - Parameters:
    ///   - contentSize: 文字の大きさの設定。nilなら端末の設定に従う。
    ///   - square: 高さを幅と同じにする。falseなら高さは64pt。
    @MainActor
    private static func tiles(_ attachment: MediaAttachment, widths: [CGFloat] = [160, 64, 40, 24], square: Bool = false, contentSize: UIContentSizeCategory? = nil) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 8
        if let contentSize {
            row.traitOverrides.preferredContentSizeCategory = contentSize
        }
        for width in widths {
            let tile = MediaTileView(store: AppDependencies.mediaImages)
            tile.apply(attachment, hiddenCount: 0, isCovered: false, policy: MediaThumbnailPolicy(allowsOriginal: true, upscaleTolerance: 2))
            tile.widthAnchor.constraint(equalToConstant: width).isActive = true
            tile.heightAnchor.constraint(equalToConstant: square ? width : 64).isActive = true
            row.addArrangedSubview(tile)
        }
        let container = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        return container
    }

    @MainActor
    /// - Parameter filterTitle: 添付ファイルをぼかすフィルターに一致したことにするなら、その名前。
    private static func grid(_ attachments: [MediaAttachment], sensitive: Bool = false, hidden: Bool = false, filterTitle: String? = nil, store: MediaImageStore = AppDependencies.mediaImages) -> UIView {
        let filtered = filterTitle.map { title in
            [FilterResult(filter: FilterResult.Filter(id: title, title: title, context: [.home], filterAction: .blur))]
        } ?? []
        let status = Status(
            id: UUID().uuidString,
            createdAt: .now,
            account: Fixtures.account(),
            content: "",
            spoilerText: "",
            url: nil,
            mediaAttachments: attachments,
            sensitive: sensitive,
            filtered: filtered
        )
        let grid = MediaGridView(store: store)
        let timeline = TimelineViewController(texts: .home, refresh: {})
        timeline.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: nil))
        if hidden {
            timeline.mediaCovers.hide(status)
        }
        guard let content = timeline.mediaContent(for: status), let aspectRatio = content.aspectRatio else { return grid }
        grid.apply(content)
        // 覆いを押したら外す。一覧と同じく、覆いと中身は同じ大きさのため高さは変わらない。
        grid.onReveal = { [weak grid] in
            grid?.apply(MediaGridView.Content(
                attachments: content.attachments,
                cover: nil,
                tallestAspectRatio: content.tallestAspectRatio,
                thumbnailPolicy: content.thumbnailPolicy,
                spacing: content.spacing
            ))
        }
        grid.heightAnchor.constraint(equalTo: grid.widthAnchor, multiplier: 1 / aspectRatio).isActive = true
        return grid
    }
}
#endif
