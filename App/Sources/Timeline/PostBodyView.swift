import SciaCore
import UIKit

/// 投稿の中身。投稿のセルと通知のセルで同じ部品を使い、どの部品をどう出すかは置く側が決める。
///
/// 上から、本文、添付ファイルの順に並べる。注意書きの折りたたみ、投票、リンクカード、引用、編集済みの印は、部品ができたらここに足す。
struct PostBodyContent {
    var text: NSAttributedString
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
}

final class PostBodyView: UIView {
    /// 本文とサムネイルのあいだの余白。
    private static let mediaSpacing: CGFloat = 8

    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?

    private let textLabel = LinkLabel()
    private let mediaView: MediaGridView
    private(set) var content: PostBodyContent?
    /// 添付ファイルの有無と並べ方で変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    /// 本文の枠。読み上げの要素の範囲を決めるときに使う。
    var textFrame: CGRect {
        textLabel.frame
    }

    init(mediaImages: MediaImageStore) {
        mediaView = MediaGridView(store: mediaImages)
        super.init(frame: .zero)
        textLabel.numberOfLines = 0
        for view in [textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: topAnchor),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.onRevealMedia?() }
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: PostBodyContent) {
        self.content = content
        textLabel.attributedText = content.text
        NSLayoutConstraint.deactivate(variableConstraints)
        if let media = content.media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            variableConstraints = [
                mediaView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: Self.mediaSpacing),
                mediaView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
                mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
                bottomAnchor.constraint(equalTo: mediaView.bottomAnchor),
            ]
        } else {
            mediaView.isHidden = true
            variableConstraints = [bottomAnchor.constraint(equalTo: textLabel.bottomAnchor)]
        }
        NSLayoutConstraint.activate(variableConstraints)
    }

    /// 読み上げで、本文のリンクを開く操作。押しても何もしないハッシュタグは除く。
    func linkAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard let text = content?.text else { return [] }
        return Self.links(in: text).map { text, destination in
            UIAccessibilityCustomAction(name: text) { [weak self] _ in
                self?.onOpenLink?(destination)
                return true
            }
        }
    }

    /// 本文のリンクを、文字と行き先の組で順に返す。書式で分かれた同じリンクはつなげる。押しても何もしないハッシュタグは除く。
    private static func links(in body: NSAttributedString) -> [(text: String, destination: RichText.LinkDestination)] {
        var result: [(text: String, destination: RichText.LinkDestination, end: Int)] = []
        body.enumerateAttribute(.linkDestination, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let destination = value as? RichText.LinkDestination else { return }
            if case .hashtag = destination { return }
            let text = (body.string as NSString).substring(with: range)
            if let last = result.last, last.destination == destination, last.end == range.location {
                result[result.count - 1] = (last.text + text, destination, NSMaxRange(range))
            } else {
                result.append((text, destination, NSMaxRange(range)))
            }
        }
        return result.map { ($0.text, $0.destination) }
    }
}
