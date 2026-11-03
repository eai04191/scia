import SciaCore
import UIKit

/// 編集履歴の版ごとの中身を、今の設定とチューニングから組み立てる。画面と部品カタログで同じ見た目にするために分けている。
@MainActor
struct EditHistoryContentBuilder {
    let tuning: TuningStore
    let settings: AppSettings
    let emojiImages: EmojiImageStore<UIImage>
    let network: NetworkConditionsMonitor

    /// 今の投稿の版から順に並べる。何を見せるかは`EditHistoryPresentation`が決め、ここでは書体と見た目を付ける。
    /// - Parameters:
    ///   - language: 投稿の言語。本文と注意書きを、その言語の書体で描く。
    ///   - latestCover: 今の投稿の版の添付ファイルをぼかす理由。ぼかさなければnil。
    ///   - isHidden: 使う人が一覧で添付ファイルを隠した。
    ///   - filterTitles: 添付ファイルをぼかすフィルターのうち、一致したものの名前。
    ///   - revealedEditNumbers: ぼかしを外した版。
    func contents(
        for history: StatusEditHistory,
        language: String?,
        latestCover: MediaCover?,
        isHidden: Bool,
        filterTitles: [String],
        revealedEditNumbers: Set<Int>,
        now: Date = AppDependencies.now()
    ) -> [EditHistoryEntryView.Content] {
        EditHistoryPresentation.entries(
            for: history,
            latestCover: latestCover,
            isHidden: isHidden,
            filterTitles: filterTitles,
            revealedEditNumbers: revealedEditNumbers
        ).map { content(for: $0, language: language, now: now) }
    }

    private func content(for entry: EditHistoryPresentation.Entry, language: String?, now: Date) -> EditHistoryEntryView.Content {
        let revision = entry.revision
        let base = UIListContentConfiguration.cell()
        let renderer = RichTextRenderer(
            font: base.secondaryTextProperties.font,
            textColor: .label,
            paragraphSpacing: settings.value(of: AppearanceCatalog.paragraphSpacing),
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
        func media(_ attachments: [MediaAttachment], cover: MediaCover?) -> MediaGridView.Content? {
            MediaGridView.Content.make(of: attachments, cover: cover, settings: settings, tuning: tuning, network: network)
        }
        return EditHistoryEntryView.Content(
            title: entry.title,
            date: StatusTimestamp.text(for: revision.createdAt, now: now, style: .absolute),
            spokenDate: StatusTimestamp.accessibilityText(for: revision.createdAt, now: now, style: .absolute),
            notes: entry.notes,
            spoiler: entry.spoiler.map { text($0, renderer: renderer) },
            body: entry.body.map { text($0, renderer: renderer) },
            media: media(revision.mediaAttachments, cover: entry.mediaCover),
            mediaChanges: entry.mediaChanges.compactMap { change in
                mediaChange(change, renderer: small) { media([$0], cover: change.cover) }
            },
            pollOptions: entry.pollOptions.map { options in
                options.map { option in
                    let attributed = NSMutableAttributedString(attributedString: renderer.render(.plain(option.text, emojis: revision.emojis)))
                    attributed.addAttributes(RichTextRenderer.attributes(for: option.change), range: NSRange(location: 0, length: attributed.length))
                    return EditHistoryEntryView.Text(attributed: attributed, accessibilityText: option.accessibilityText)
                }
            },
            spacing: settings.value(of: AppearanceCatalog.bodyMediaSpacing),
            animatedEmojis: settings.animatesCustomEmojis ? emojiImages : nil
        )
    }

    private func mediaChange(
        _ change: EditHistoryPresentation.MediaChange,
        renderer: RichTextRenderer,
        thumbnail: (MediaAttachment) -> MediaGridView.Content?
    ) -> EditHistoryEntryView.MediaChange? {
        guard var content = thumbnail(change.attachment) else { return nil }
        content.arrangement = .strip(side: 44)
        let attributed = NSMutableAttributedString(string: change.title, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.secondaryLabel,
        ])
        var accessibilityText = change.title
        if let detail = change.detail {
            attributed.append(NSAttributedString(string: "\n"))
            attributed.append(renderer.render(detail))
            accessibilityText += "、\(RichTextRenderer.accessibilityText(of: detail))"
        }
        return EditHistoryEntryView.MediaChange(
            thumbnail: content,
            text: EditHistoryEntryView.Text(attributed: attributed, accessibilityText: accessibilityText),
            isRemoved: change.isRemoved
        )
    }
}
