import SciaCore
import UIKit

/// 投稿の中身。投稿のセルと通知のセルで同じ部品を使い、どの部品をどう出すかは置く側が決める。
///
/// 上から、注意書き、本文、添付ファイルの順に並べる。投票、リンクカード、引用、編集済みの印は、部品ができたらここに足す。
/// 注意書きで畳んでいる間は、注意書きだけを出す。
/// 本文が空なら、本文と添付ファイルのあいだの余白も取らず、添付ファイルを上端から置く。上の行との間隔は置く側が`startsWithMedia`を見て決める。
struct PostBodyContent {
    struct Spoiler {
        var text: NSAttributedString
        var isCollapsed: Bool
        /// 注意書きの箱の内側の余白。
        var padding: CGFloat
        /// 開いているときの、注意書きの箱と本文のあいだ。
        var bodySpacing: CGFloat
    }

    /// 注意書きがなければnil。
    var spoiler: Spoiler?
    var text: NSAttributedString
    /// 本文を切る行数。0なら切らない。
    var maximumLines = 0
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    /// 本文と添付ファイルのあいだの余白。本文がなければ取らない。
    var mediaSpacing: CGFloat
}

final class PostBodyView: UIView {
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?
    /// 注意書きが押されたときに呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?

    private let spoilerView = SpoilerView()
    private let textLabel = LinkLabel()
    private let mediaView: MediaGridView
    private(set) var content: PostBodyContent?
    /// 添付ファイルの有無と並べ方で変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    /// 注意書きも本文もなく、添付ファイルが上端から始まる。
    var startsWithMedia: Bool {
        spoilerView.isHidden && textLabel.isHidden && !mediaView.isHidden
    }

    /// 注意書きと本文の枠。読み上げの要素の範囲を決めるときに使う。
    var textFrame: CGRect {
        [spoilerView, textLabel].filter { !$0.isHidden }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    init(mediaImages: MediaImageStore) {
        mediaView = MediaGridView(store: mediaImages)
        super.init(frame: .zero)
        textLabel.numberOfLines = 0
        for view in [spoilerView, textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spoilerView.topAnchor.constraint(equalTo: topAnchor),
            spoilerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            spoilerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.onRevealMedia?() }
        spoilerView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?() }, for: .touchUpInside)
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: PostBodyContent) {
        self.content = content
        textLabel.attributedText = Self.truncatingTail(content.text, when: content.maximumLines > 0)
        textLabel.numberOfLines = content.maximumLines
        NSLayoutConstraint.deactivate(variableConstraints)
        variableConstraints = []
        if let spoiler = content.spoiler {
            spoilerView.isHidden = false
            spoilerView.apply(SpoilerView.Content(text: spoiler.text, isCollapsed: spoiler.isCollapsed, padding: spoiler.padding))
        } else {
            spoilerView.isHidden = true
        }
        let isCollapsed = content.spoiler?.isCollapsed ?? false
        let media = isCollapsed ? nil : content.media.flatMap { $0.aspectRatio == nil ? nil : $0 }
        textLabel.isHidden = isCollapsed || (content.text.length == 0 && (media != nil || content.spoiler != nil))
        // 本文と添付ファイルは、注意書きがあればその下から並べる。
        let contentTop = content.spoiler.map { (anchor: spoilerView.bottomAnchor, spacing: $0.bodySpacing) } ?? (anchor: topAnchor, spacing: 0)
        if !textLabel.isHidden {
            variableConstraints.append(textLabel.topAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing))
        }
        if let media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            let mediaTop = textLabel.isHidden
                ? mediaView.topAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing)
                : mediaView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: content.mediaSpacing)
            variableConstraints += [
                mediaTop,
                mediaView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottomAnchor.constraint(equalTo: mediaView.bottomAnchor),
            ]
            let height = switch media.arrangement {
            case .grid: mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio)
            case .strip(let side): mediaView.heightAnchor.constraint(equalToConstant: side)
            }
            variableConstraints.append(height)
        } else {
            mediaView.isHidden = true
            // 添付ファイルがないのに本文を隠すのは、注意書きがあるときだけ。
            let last: UIView = textLabel.isHidden ? spoilerView : textLabel
            variableConstraints.append(bottomAnchor.constraint(equalTo: last.bottomAnchor))
        }
        NSLayoutConstraint.activate(variableConstraints)
    }

    /// 読み上げで、注意書きの本文を開閉する操作。注意書きがなければnil。
    func spoilerAccessibilityAction() -> UIAccessibilityCustomAction? {
        guard let spoiler = content?.spoiler else { return nil }
        return UIAccessibilityCustomAction(name: SpoilerView.toggleTitle(isCollapsed: spoiler.isCollapsed)) { [weak self] _ in
            self?.onToggleSpoiler?()
            return true
        }
    }

    /// 読み上げる文。注意書きがあれば先に読み、畳んでいる間は本文を読まない。
    var accessibilityText: String {
        guard let content else { return "" }
        guard let spoiler = content.spoiler else { return content.text.string }
        let parts = ["注意書き", spoiler.text.string] + (spoiler.isCollapsed ? [] : [content.text.string])
        return parts.filter { !$0.isEmpty }.joined(separator: "、")
    }

    /// 行数で切る本文の末尾に、省略記号を出す。本文の段落は折り返しの指定を持ち、そのままでは最後の行が黙って切れるため。
    /// UILabelは、複数行のときの末尾の省略を折り返したうえで最後の行に当てる。
    private static func truncatingTail(_ text: NSAttributedString, when truncates: Bool) -> NSAttributedString {
        guard truncates else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.lineBreakMode = .byTruncatingTail
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// 読み上げで、本文のリンクを開く操作。押しても何もしないハッシュタグは除く。
    func linkAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard let text = content?.text, content?.spoiler?.isCollapsed != true else { return [] }
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
