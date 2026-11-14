import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 「投稿の見た目」で、投稿の部品を表示しない選択肢。決まりはdocs/appearance.mdの「部品を表示しない」にある。
@Suite(.scratch, .failureState)
@MainActor
struct HiddenPostPartsTests {
    private func status(content: String = "<p>本文の1行目です。</p>", spoilerText: String = "", visibility: Status.Visibility = .public, edited: Bool = false, media: Bool = false) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
        return Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media ? [attachment] : [],
            visibility: visibility,
            editedAt: edited ? base.createdAt : nil
        )
    }

    private func timeline(_ change: (AppSettings) -> Void) -> TimelineViewController {
        let settings = AppSettings.isolated()
        change(settings)
        return TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
    }

    /// タイムラインのセルと同じく高さを測って並べる。
    private func laidOut(_ configuration: PostContentConfiguration) -> PostContentView {
        let view = PostContentView(configuration: configuration)
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    private func visibleLabels(in view: UIView) -> [UILabel] {
        view.subviews.filter { !$0.isHidden }.flatMap { subview in
            (subview as? UILabel).map { [$0] } ?? visibleLabels(in: subview)
        }
    }

    private func spokenLabel(of view: PostContentView) throws -> String {
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        return try #require(element.accessibilityLabel)
    }

    // MARK: 時刻

    /// 時刻を出さなくても、公開範囲の記号と編集済みの「*」は、それぞれのスイッチに従って出す。
    @Test func hiddenTimeKeepsVisibilitySymbolAndEditedMark() throws {
        let configuration = timeline { $0.appearance.showsTime = false }
            .contentConfiguration(for: try status(visibility: .private, edited: true), base: .cell())
        let view = laidOut(configuration)

        let text = try #require(visibleLabels(in: view).compactMap(\.attributedText).first { $0.string.contains("*") })
        #expect(text.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
        // 記号、すき間を作る空白、「*」だけで、時刻の文字はない。
        #expect(text.length == 3)
        let frames = view.previewFrames()
        #expect(frames[.visibilitySymbol] != nil)
        #expect(frames[.editedMark] != nil)
    }

    /// 時刻も記号も「*」も出さなければ、時刻のラベルを出さない。
    @Test func hiddenTimeWithoutMarksHidesTimeLabel() throws {
        let configuration = timeline {
            $0.appearance.showsTime = false
            $0.appearance.showsVisibilitySymbol = false
            $0.appearance.showsEditedMark = false
        }
        .contentConfiguration(for: try status(visibility: .private, edited: true), base: .cell())
        let view = laidOut(configuration)

        #expect(view.previewFrames()[.time] == nil)
        // 消した記号と「*」の場所は、名前の行の右端で示す。
        #expect(view.previewFrames()[.visibilitySymbol] != nil)
        #expect(view.previewFrames()[.editedMark] != nil)
        #expect(try spokenLabel(of: view).contains("フォロワーのみ、編集済み、"))
    }
}
