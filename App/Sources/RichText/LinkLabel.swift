import SciaCore
import UIKit

/// RichTextRendererで描いた本文の、リンクの部分をタップできるラベル。リンクの外のタップは受けず、セルなど後ろのビューに渡す。
final class LinkLabel: UILabel {
    /// 長押しのメニューの並び。
    var settings: AppSettings = AppDependencies.settings

    /// リンクがタップされたときと、メンションの長押しのメニューでプロフィールを選んだときに、その行き先を渡して呼ぶ。
    var onTapLink: ((RichText.LinkDestination) -> Void)?

    override var attributedText: NSAttributedString? {
        didSet { layoutCache = nil }
    }

    override var text: String? {
        didSet { layoutCache = nil }
    }

    override var numberOfLines: Int {
        didSet { layoutCache = nil }
    }

    override var lineBreakMode: NSLineBreakMode {
        didSet { layoutCache = nil }
    }

    /// `link(at:)`で並べ直した結果。ポインタを動かすたびに`hitArea`の`point(inside:with:)`から呼ばれるため、文字列と幅が変わるまで使い回す。
    private var layoutCache: TextLayout?

    /// リンクの上の押下だけを受ける、ラベルと同じ大きさの透明な部品。
    /// MacのDesigned for iPadでは、アクティブでないウィンドウへの最初のクリックを、押された場所のビューが`UIControl`のときだけアプリに渡し、
    /// それ以外はウィンドウを前に出すだけで捨てる。ラベルにタップのジェスチャーを付けるだけだと、リンクを押してもまずウィンドウが前に出るだけになるため、
    /// リンクの上で押されたビューが`UIControl`になるようにする。
    private lazy var hitArea = LinkHitArea(label: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        hitArea.frame = bounds
        hitArea.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hitArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func tapped(at point: CGPoint) {
        guard let destination = link(at: point) else { return }
        onTapLink?(destination)
    }

    fileprivate func open(_ destination: RichText.LinkDestination) {
        onTapLink?(destination)
    }

    /// ラベルの座標`point`にある文字のリンクの行き先。リンクでなければnil。
    /// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して文字を探す。
    /// TextKit 1（NSLayoutManager）で並べると、空行や行区切り文字のたびに行の位置がUILabelの描画から数ptずつずれ、
    /// 空行の多い本文では末尾のリンクを外していた。TextKit 2の行の位置は、UILabelが描いた位置と一致することを確かめている。
    /// ラベルは本文の高さに合わせて置くため、UILabelが余った高さで文字を縦に中央へ寄せる分はずれとして扱わない。
    func link(at point: CGPoint) -> RichText.LinkDestination? {
        guard let attributedText, let index = characterIndex(at: point) else { return nil }
        return attributedText.attribute(.linkDestination, at: index, effectiveRange: nil) as? RichText.LinkDestination
    }

    /// ラベルの座標`point`にあるリンクの、文字が描かれる枠。行をまたぐリンクは行ごとの枠になる。リンクでなければ空。
    func linkFrames(at point: CGPoint) -> [CGRect] {
        guard let attributedText, let index = characterIndex(at: point) else { return [] }
        var range = NSRange()
        guard attributedText.attribute(.linkDestination, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: attributedText.length)) != nil else { return [] }
        let layout = textLayout(of: attributedText)
        let contentStorage = layout.contentStorage
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        var frames: [CGRect] = []
        layout.layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            frames.append(segment)
            return true
        }
        return frames
    }

    /// ラベルの座標`point`にある文字の位置。文字の上でなければnil。
    private func characterIndex(at point: CGPoint) -> Int? {
        guard let attributedText, attributedText.length > 0, bounds.contains(point) else { return nil }
        let layout = textLayout(of: attributedText)
        let contentStorage = layout.contentStorage
        let layoutManager = layout.layoutManager

        guard let fragment = layoutManager.textLayoutFragment(for: point),
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }
        let pointInFragment = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        // 行末より右や最終行より下を押しても、いちばん近い文字が返るため、文字の枠の中かを確かめる。
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(pointInFragment) }),
              pointInFragment.x <= line.typographicBounds.minX + line.typographicBounds.width
        else { return nil }
        let pointInLine = CGPoint(x: pointInFragment.x - line.typographicBounds.minX, y: pointInFragment.y - line.typographicBounds.minY)
        let indexInLine = line.characterIndex(for: pointInLine)
        guard indexInLine != NSNotFound,
              let boundary = contentStorage.location(paragraphStart, offsetBy: indexInLine)
        else { return nil }
        let boundaryIndex = contentStorage.offset(from: contentStorage.documentRange.location, to: boundary)
        // 返るのは文字と文字の境目で、押した文字の前か後ろかは書く向きで変わる。境目の前後の文字のうち、描かれた枠に押した点が入るほうを選ぶ。
        let candidates = [boundaryIndex, boundaryIndex - 1].filter { 0 <= $0 && $0 < attributedText.length }
        return candidates.first { characterFrame(at: $0, in: contentStorage, layoutManager: layoutManager)?.contains(point) ?? false }
    }

    /// `attributedText`をラベルと同じ幅で並べた結果。幅か画面の向きが変わったときだけ並べ直す。
    private func textLayout(of attributedText: NSAttributedString) -> TextLayout {
        let direction = effectiveUserInterfaceLayoutDirection
        if let layoutCache, layoutCache.width == bounds.width, layoutCache.direction == direction {
            return layoutCache
        }
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 高さは限らない。最後の行の下の行間まで数えるとラベルより高くなり、ラベルの高さで切ると最後の行が並ばない。
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: 0))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        layoutManager.textContainer = container
        contentStorage.attributedString = alignedLikeLabel(attributedText)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let layout = TextLayout(width: bounds.width, direction: direction, contentStorage: contentStorage, layoutManager: layoutManager)
        layoutCache = layout
        return layout
    }

    /// 行の寄せ方を、UILabelが描くのと同じにした文字列。
    /// 寄せ方が「自然」のとき、UILabelは画面の向き（日本語なら左から右）で寄せるが、TextKit 2は段落の文字の向きで寄せ、
    /// ヘブライ語やアラビア語の段落を右に寄せる。そのままだと行の置き場所がまるごとずれ、リンクを外すため、画面の向きに合わせて決めておく。
    private func alignedLikeLabel(_ text: NSAttributedString) -> NSAttributedString {
        let resolved: NSTextAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            guard style.alignment == .natural else { return }
            style.alignment = resolved
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// `index`の文字が描かれる枠。ラベルの座標で返す。
    private func characterFrame(at index: Int, in contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: index),
              let end = contentStorage.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end)
        else { return nil }
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            frame = frame.map { $0.union(segment) } ?? segment
            return true
        }
        return frame
    }
}

/// `LinkLabel`の文字を並べた結果と、並べたときの条件。
private struct TextLayout {
    let width: CGFloat
    let direction: UIUserInterfaceLayoutDirection
    let contentStorage: NSTextContentStorage
    let layoutManager: NSTextLayoutManager
}

/// 本文のリンクの長押しのメニューを出す画面。ラベルはレスポンダーチェーンをさかのぼって、いちばん近いものに知らせる。
@MainActor
protocol LinkMenuHost: AnyObject {
    /// メニューを出した。メニューの元になった行が動かないよう、閉じるまで一覧の更新を溜めておく。
    func linkMenuWillShow()
    /// メニューが閉じるアニメーションまで終わった。
    func linkMenuDidHide()
    /// 「リンクをコピー」を選んだ。
    func showLinkCopiedNotice()
    /// 開く項目を選んだ。`browser`は選んだ項目と開く場所の設定から決めた、実際に開く場所。
    func openURL(_ url: URL, in browser: LinkBrowser)
}

/// `LinkLabel`の上に重ねる、リンクの上だけを当たりにする部品。リンクの外では当たりにならず、押下はラベルの後ろのセルへ渡る。
/// スクロールビューは標準では`UIControl`の上で始まった押下をスクロールに切り替えないため、載せるスクロールビューは`touchesShouldCancel(in:)`でこの部品にtrueを返す。
/// リンクの上の長押しは、セルの後ろのコレクションビューに渡らず投稿のメニューにならないため、この部品でリンクのメニューを出す。
final class LinkHitArea: UIControl {
    private weak var label: LinkLabel?

    init(label: LinkLabel) {
        self.label = label
        super.init(frame: .zero)
        isAccessibilityElement = false
        isContextMenuInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let label else { return false }
        return label.link(at: convert(point, to: label)) != nil
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard let touch, let label, isTouchInside else { return }
        label.tapped(at: touch.location(in: label))
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let label else { return nil }
        let point = convert(location, to: label)
        // 出す項目をすべて隠していれば、メニューを出さない。
        guard let destination = label.link(at: point), let menu = menu(for: destination, at: point) else { return nil }
        // 浮かせるリンクを選び直せるよう、押した場所をidentifierに持たせる。
        return UIContextMenuConfiguration(identifier: NSValue(cgPoint: point), previewProvider: nil) { _ in menu }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        linkPreview(for: configuration)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        linkPreview(for: configuration)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        nearest((any LinkMenuHost).self)?.linkMenuWillShow()
    }

    /// 閉じるアニメーションの間も行を動かさない。
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        // 閉じ終わる前にセルが使い回されてもよいよう、知らせる先は閉じ始めに決めておく。
        let host = nearest((any LinkMenuHost).self)
        guard let animator else {
            host?.linkMenuDidHide()
            return
        }
        animator.addCompletion { host?.linkMenuDidHide() }
    }

    /// 押したリンクの文字だけを浮かせる。部品はラベルと同じ大きさで透明なため、そのままでは本文の全体が浮く。
    private func linkPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let label, let point = (configuration.identifier as? NSValue)?.cgPointValue else { return nil }
        let frames = label.linkFrames(at: point)
        guard !frames.isEmpty else { return nil }
        return UITargetedPreview(view: label, parameters: UIPreviewParameters(textLineRects: frames.map { NSValue(cgRect: $0) }))
    }

    /// 並びは設定のリンクのメニューとハッシュタグのメニューに従う。メンションはユーザーなので、ユーザーのメニューで出す。出す項目がなければnil。
    /// 開く項目は、メニューを出した画面に開く場所を渡して開かせる。アプリ内のSafariはセッションが持つため、ラベルからは開けない。
    func menu(for destination: RichText.LinkDestination, at point: CGPoint) -> UIMenu? {
        guard let label else { return nil }
        let settings = label.settings
        let handlers = urlHandlers(at: point, linkBrowser: settings.linkBrowser)
        let title: String
        let children: [UIMenuElement]
        switch destination {
        case .url(let url):
            title = url.absoluteString
            children = settings.linkMenuLayout.groups.menuElements { item in
                switch item.content {
                case .url(let action, _): [action.action(url: url, handlers: handlers)]
                // リンクのメニューの項目は、どれも共通の項目。
                case .own: []
                }
            }
        case .mention(let acct, let url):
            title = "@\(acct)"
            children = settings.userMenuLayout.groups.menuElements { item in
                if let action = item.urlAction {
                    return [action.action(url: url, handlers: handlers)]
                }
                switch item {
                case .profile: return [profileAction(item.title, image: item.image, destination)]
                // 共通の項目は、上で中身から組んだ。
                case .copyLink, .share: return []
                }
            }
        case .hashtag(let name, let url):
            title = "#\(name)"
            children = settings.hashtagMenuLayout.groups.menuElements { item in
                switch item.content {
                case .url(let action, _): [action.action(url: url, handlers: handlers)]
                // ハッシュタグのメニューの項目は、どれも共通の項目。
                case .own: []
                }
            }
        }
        return children.isEmpty ? nil : UIMenu(title: title, children: children)
    }

    private func profileAction(_ title: String, image: UIImage?, _ destination: RichText.LinkDestination) -> UIAction {
        UIAction(title: title, image: image) { [weak self] _ in self?.label?.open(destination) }
    }

    /// コピーと開くは、メニューを出した画面に頼む。共有のシートは、押したリンクから出す。
    private func urlHandlers(at point: CGPoint, linkBrowser: LinkBrowser) -> URLMenuHandlers {
        URLMenuHandlers(
            linkBrowser: linkBrowser,
            copy: { [weak self] url in URLSharing.copy(url, notifying: self?.nearest((any LinkMenuHost).self)) },
            share: { [weak self] url in self?.presentShareSheet(for: url, at: point) },
            open: { [weak self] url, browser in self?.nearest((any LinkMenuHost).self)?.openURL(url, in: browser) }
        )
    }

    private func presentShareSheet(for url: URL, at point: CGPoint) {
        guard let label, let presenter = nearest(UIViewController.self) else { return }
        URLSharing.presentShareSheet(for: url, from: presenter) { popover in
            popover.sourceView = label
            popover.sourceRect = label.linkFrames(at: point).reduce(CGRect.null) { $0.union($1) }
        }
    }

    private func nearest<T>(_ type: T.Type) -> T? {
        sequence(first: self as UIResponder, next: \.next).lazy.compactMap { $0 as? T }.first
    }
}
