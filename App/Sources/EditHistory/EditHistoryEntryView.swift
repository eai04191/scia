import SciaCore
import UIKit

/// 編集履歴の1つの版。見出し、本文と注意書きのほかに変わったこと、注意書き、本文、添付ファイル、添付ファイルの変更、投票の選択肢を縦に並べる。
///
/// 添付ファイルの変更は、サムネイルに印を重ねず、サムネイルと文字の行で書き出す。サムネイルにはALTやGIFの印、動画の記号、残りの枚数がすでに載っていて、
/// 追加や削除の印を重ねる場所がないため。
final class EditHistoryEntryView: UIView {
    struct Content {
        var title: String
        var date: String
        /// 閲覧注意を付けた、並びを変えた、のような、文字の行で知らせる変更。
        var notes: [String]
        var spoiler: Text?
        var body: Text?
        var media: MediaGridView.Content?
        var mediaChanges: [MediaChange]
        /// 投票の選択肢。投票のない版ではnil。
        var pollOptions: [Text]?
        var spacing: CGFloat
        /// アニメーションするカスタム絵文字を動かすときに、アニメーション版を読む置き場。nilなら動かさない。
        var animatedEmojis: EmojiImageStore?
    }

    /// 差分を重ねた文字と、その読み上げ。
    struct Text {
        var attributed: NSAttributedString
        var accessibilityText: String
    }

    struct MediaChange {
        var thumbnail: MediaGridView.Content
        var text: Text
        /// 前の版にあって、この版で外された。サムネイルを薄く描く。
        var isRemoved: Bool
    }

    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 閲覧注意の覆いが押されたときに呼ぶ。覆いを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    /// サムネイルが押されたときに、並んでいる添付ファイルと何番目かと、押されたサムネイルの置き場所を渡して呼ぶ。
    var onSelectMedia: (([MediaAttachment], Int, MediaPlace) -> Void)?

    /// サムネイルの置き場所。ビューアを閉じるときに、押したサムネイルへ戻すために使う。
    enum MediaPlace: Hashable {
        /// 版の添付ファイル。
        case revision
        /// 添付ファイルの変更の行。何番目の行か。
        case change(Int)
    }

    private let mediaImages: MediaImageStore
    /// いま当てている中身の、動く絵文字の置き場。文字のラベルを作るときに渡す。
    private var animatedEmojis: EmojiImageStore?
    private let stack = UIStackView()
    private var mediaGrids: [MediaPlace: MediaGridView] = [:]

    init(mediaImages: MediaImageStore) {
        self.mediaImages = mediaImages
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 中身を並べ直す。版ごとに並ぶものが違うため、部品を作り直す。
    func apply(_ content: Content) {
        animatedEmojis = content.animatedEmojis
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        mediaGrids = [:]
        stack.spacing = content.spacing
        stack.addArrangedSubview(header(title: content.title, date: content.date))
        if !content.notes.isEmpty {
            let label = Self.label(font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel)
            label.text = content.notes.joined(separator: "\n")
            stack.addArrangedSubview(label)
        }
        if let spoiler = content.spoiler {
            stack.addArrangedSubview(spoilerView(spoiler))
        }
        if let body = content.body {
            let label = LinkLabel()
            label.numberOfLines = 0
            label.emojiImages = animatedEmojis
            label.attributedText = body.attributed
            label.accessibilityLabel = body.accessibilityText
            label.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
            stack.addArrangedSubview(label)
        }
        if let media = content.media {
            stack.addArrangedSubview(mediaView(media))
        }
        for (index, change) in content.mediaChanges.enumerated() {
            stack.addArrangedSubview(mediaChangeRow(change, place: .change(index)))
        }
        if let options = content.pollOptions {
            stack.addArrangedSubview(pollView(options))
        }
    }

    private func header(title: String, date: String) -> UIView {
        let titleLabel = Self.label(font: .preferredFont(forTextStyle: .subheadline).bold, color: .label)
        titleLabel.text = title
        let dateLabel = Self.label(font: .preferredFont(forTextStyle: .subheadline), color: .secondaryLabel)
        dateLabel.text = date
        dateLabel.numberOfLines = 1
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [titleLabel, dateLabel])
        row.spacing = 8
        row.alignment = .firstBaseline
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(title)、\(date)"
        row.accessibilityTraits = .header
        return row
    }

    /// 注意書きは、一覧の注意書きと同じく箱に入れ、本文と見分ける。
    private func spoilerView(_ spoiler: Text) -> UIView {
        let label = Self.label(font: .preferredFont(forTextStyle: .subheadline), color: .label)
        label.emojiImages = animatedEmojis
        label.attributedText = spoiler.attributed
        label.accessibilityLabel = "注意書き、\(spoiler.accessibilityText)"
        let box = UIView()
        box.backgroundColor = .secondarySystemFill
        box.layer.cornerRadius = 8
        box.layer.cornerCurve = .continuous
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.layoutMarginsGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: box.layoutMarginsGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: box.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: box.layoutMarginsGuide.trailingAnchor),
        ])
        return box
    }

    /// 置き場所に並べているサムネイル。並べていなければnil。
    func mediaGrid(at place: MediaPlace) -> MediaGridView? {
        mediaGrids[place]
    }

    private func makeMediaGrid(_ content: MediaGridView.Content, place: MediaPlace) -> MediaGridView {
        let view = MediaGridView(store: mediaImages)
        view.apply(content)
        view.onReveal = { [weak self] in self?.onRevealMedia?() }
        view.onSelect = { [weak self] index in self?.onSelectMedia?(content.attachments, index, place) }
        mediaGrids[place] = view
        return view
    }

    private func mediaView(_ content: MediaGridView.Content) -> UIView {
        let view = makeMediaGrid(content, place: .revision)
        if let aspectRatio = content.aspectRatio {
            view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / aspectRatio).isActive = true
        }
        return view
    }

    private func mediaChangeRow(_ change: MediaChange, place: MediaPlace) -> UIView {
        let thumbnail = makeMediaGrid(change.thumbnail, place: place)
        thumbnail.alpha = change.isRemoved ? 0.4 : 1
        let side: CGFloat = if case .strip(let side) = change.thumbnail.arrangement { side } else { 44 }
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: side),
            thumbnail.heightAnchor.constraint(equalToConstant: side),
        ])
        let label = Self.label(font: .preferredFont(forTextStyle: .footnote), color: .label)
        label.emojiImages = animatedEmojis
        label.attributedText = change.text.attributed
        label.accessibilityLabel = change.text.accessibilityText
        let row = UIStackView(arrangedSubviews: [thumbnail, label])
        row.spacing = 10
        row.alignment = .center
        return row
    }

    private func pollView(_ options: [Text]) -> UIView {
        let title = Self.label(font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel)
        title.text = "投票の選択肢"
        let column = UIStackView(arrangedSubviews: [title])
        column.axis = .vertical
        column.spacing = 4
        for option in options {
            let label = Self.label(font: .preferredFont(forTextStyle: .subheadline), color: .label)
            label.emojiImages = animatedEmojis
            label.attributedText = option.attributed
            label.accessibilityLabel = option.accessibilityText
            column.addArrangedSubview(label)
        }
        return column
    }

    private static func label(font: UIFont, color: UIColor) -> EmojiLabel {
        let label = EmojiLabel()
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}
