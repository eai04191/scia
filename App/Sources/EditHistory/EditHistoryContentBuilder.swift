import SciaCore
import UIKit

/// 編集履歴の版ごとの中身を、今の設定とチューニングから組み立てる。画面と部品カタログで同じ見た目にするために分けている。
@MainActor
struct EditHistoryContentBuilder {
    let tuning: TuningStore
    let settings: AppSettings
    let emojiImages: EmojiImageStore
    let network: NetworkConditionsMonitor

    /// 今の投稿の版から順に並べる。
    /// - Parameters:
    ///   - language: 投稿の言語。本文と注意書きを、その言語の書体で描く。
    ///   - revealedEditNumbers: 閲覧注意の覆いを外した版。
    func contents(for history: StatusEditHistory, language: String?, revealedEditNumbers: Set<Int>, now: Date = .now) -> [EditHistoryEntryView.Content] {
        history.entries.enumerated().map { index, entry in
            content(
                for: entry,
                previous: history.entries.indices.contains(index + 1) ? history.entries[index + 1].revision : nil,
                isLatest: index == 0,
                language: language,
                isRevealed: revealedEditNumbers.contains(entry.editNumber),
                now: now
            )
        }
    }

    /// - Parameter previous: 1つ前の版。最初の投稿ではnil。
    private func content(
        for entry: StatusEditHistory.Entry,
        previous: StatusRevision?,
        isLatest: Bool,
        language: String?,
        isRevealed: Bool,
        now: Date
    ) -> EditHistoryEntryView.Content {
        let revision = entry.revision
        let base = UIListContentConfiguration.cell()
        let renderer = RichTextRenderer(
            font: base.secondaryTextProperties.font,
            textColor: .label,
            paragraphSpacing: tuning.value(of: TuningCatalog.paragraphSpacing),
            emojiImages: emojiImages,
            language: settings.glyphLanguageIdentifier(for: language)
        )
        let small = RichTextRenderer(
            font: .preferredFont(forTextStyle: .footnote),
            textColor: .label,
            emojiImages: emojiImages,
            language: settings.glyphLanguageIdentifier(for: language)
        )
        func text(_ diff: RichTextDiff, renderer: RichTextRenderer) -> EditHistoryEntryView.Text {
            EditHistoryEntryView.Text(attributed: renderer.render(diff), accessibilityText: RichTextRenderer.accessibilityText(of: diff))
        }
        // 一覧と同じく、閲覧注意か注意書きのある版は、タップするまで添付ファイルを覆う。
        func cover(of revision: StatusRevision?) -> MediaCover? {
            guard let revision, revision.sensitive || !revision.spoilerText.isEmpty, !isRevealed else { return nil }
            return .sensitive
        }
        func media(_ attachments: [MediaAttachment], cover: MediaCover?) -> MediaGridView.Content? {
            MediaGridView.Content.make(of: attachments, cover: cover, settings: settings, tuning: tuning, network: network)
        }
        let title = entry.isOriginal ? "最初の投稿" : "\(entry.editNumber)回目の編集"
        return EditHistoryEntryView.Content(
            title: isLatest ? "いまの投稿（\(title)）" : title,
            date: StatusTimestamp.text(for: revision.createdAt, now: now, style: .absolute),
            notes: (Self.changesFirstBlockLayout(entry.body) ? ["段落の形を変えた"] : []) + entry.changes.compactMap { note(for: $0, in: revision) },
            spoiler: entry.spoiler.map { text($0, renderer: renderer) },
            body: entry.body.blocks.isEmpty ? nil : text(entry.body, renderer: renderer),
            media: media(revision.mediaAttachments, cover: cover(of: revision)),
            mediaChanges: entry.changes.compactMap { change in
                // 外した添付ファイルは、外す前の版にあったものなので、その版の閲覧注意で覆う。
                // この版で閲覧注意を外していても、外す前に覆っていた画像を、開いただけで見せない。
                let thumbnailCover = if case .mediaRemoved = change { cover(of: previous) } else { cover(of: revision) }
                return mediaChange(for: change, renderer: small) { media([$0], cover: thumbnailCover) }
            },
            pollOptions: pollOptions(of: entry, renderer: renderer),
            spacing: tuning.value(of: TuningCatalog.bodyMediaSpacing)
        )
    }

    /// 先頭の段落の形（引用かどうかなど）だけを変えた。2つ目からの段落は、区切りに足した改行の印で示せるが、先頭には印を置く場所がないため、文字で知らせる。
    private static func changesFirstBlockLayout(_ body: RichTextDiff) -> Bool {
        guard let first = body.blocks.first else { return false }
        return first.breakChange == .inserted && first.pieces.first?.change != .inserted
    }

    private func note(for change: StatusEditHistory.Change, in revision: StatusRevision) -> String? {
        switch change {
        case .sensitiveAdded: "閲覧注意を付けた"
        case .sensitiveRemoved: "閲覧注意を外した"
        case .mediaReordered:
            revision.mediaAttachments.allSatisfy { $0.type == .image } ? "画像の並びを変えた" : "メディアの並びを変えた"
        case .mediaAdded, .mediaRemoved, .mediaDescriptionChanged, .pollOptions: nil
        }
    }

    private func mediaChange(
        for change: StatusEditHistory.Change,
        renderer: RichTextRenderer,
        thumbnail: (MediaAttachment) -> MediaGridView.Content?
    ) -> EditHistoryEntryView.MediaChange? {
        func row(_ attachment: MediaAttachment, title: String, detail: RichTextDiff?, isRemoved: Bool) -> EditHistoryEntryView.MediaChange? {
            guard var content = thumbnail(attachment) else { return nil }
            content.arrangement = .strip(side: 44)
            let attributed = NSMutableAttributedString(string: title, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: UIColor.secondaryLabel,
            ])
            var accessibilityText = title
            if let detail {
                attributed.append(NSAttributedString(string: "\n"))
                attributed.append(renderer.render(detail))
                accessibilityText += "、\(RichTextRenderer.accessibilityText(of: detail))"
            }
            return EditHistoryEntryView.MediaChange(
                thumbnail: content,
                text: EditHistoryEntryView.Text(attributed: attributed, accessibilityText: accessibilityText),
                isRemoved: isRemoved
            )
        }
        switch change {
        case .mediaAdded(let attachment):
            return row(attachment, title: "\(MediaTileView.kindName(of: attachment.type))を追加", detail: nil, isRemoved: false)
        case .mediaRemoved(let attachment):
            return row(attachment, title: "\(MediaTileView.kindName(of: attachment.type))を削除", detail: nil, isRemoved: true)
        case .mediaDescriptionChanged(let attachment, let description):
            return row(attachment, title: "代替テキストを変更", detail: description, isRemoved: false)
        case .sensitiveAdded, .sensitiveRemoved, .mediaReordered, .pollOptions:
            return nil
        }
    }

    /// 選択肢が変わった版では違いを重ね、変わっていない版ではこの版の選択肢をそのまま並べる。
    private func pollOptions(of entry: StatusEditHistory.Entry, renderer: RichTextRenderer) -> [EditHistoryEntryView.Text]? {
        let options: [StatusEditHistory.PollOption]? = entry.changes.lazy.compactMap { change in
            if case .pollOptions(let options) = change { options } else { nil }
        }.first ?? entry.revision.pollOptions?.map { StatusEditHistory.PollOption($0, .unchanged) }
        guard let options, !options.isEmpty else { return nil }
        return options.map { option in
            let attributed = NSMutableAttributedString(attributedString: renderer.render(.plain("・\(option.title)", emojis: entry.revision.emojis)))
            attributed.addAttributes(RichTextRenderer.attributes(for: option.change), range: NSRange(location: 0, length: attributed.length))
            let accessibilityText = switch option.change {
            case .unchanged: option.title
            case .inserted: "追加：\(option.title)"
            case .removed: "削除：\(option.title)"
            }
            return EditHistoryEntryView.Text(attributed: attributed, accessibilityText: accessibilityText)
        }
    }
}
