import SciaCore
import UIKit

/// RichTextRendererで描いた本文の、リンクの部分をタップできるラベル。リンクの外のタップは受けず、セルなど後ろのビューに渡す。
final class LinkLabel: EmojiLabel {
    /// 長押しのメニューの並び。
    var settings: AppSettings = AppDependencies.settings

    /// リンクがタップされたときと、メンションの長押しのメニューでプロフィールを選んだときに、その行き先を渡して呼ぶ。
    var onTapLink: ((RichText.LinkDestination) -> Void)?

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

    /// リンクの外では当たりにならず、押下は後ろのビューに渡る。リンクの上では、重ねた`hitArea`が当たりになる。
    /// ラベル自身が当たりになると、Xの投稿の囲みのようにボタンの中に置いたとき、リンクの外を押してもボタンが反応しない。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    fileprivate func tapped(at point: CGPoint) {
        guard let destination = link(at: point) else { return }
        onTapLink?(destination)
    }

    fileprivate func open(_ destination: RichText.LinkDestination) {
        onTapLink?(destination)
    }

    /// 本文のリンクを、文字と行き先の組で順に返す。書式で分かれた同じリンクはつなげる。押しても何もしないハッシュタグは除く。
    static func links(in body: NSAttributedString) -> [(text: String, destination: RichText.LinkDestination)] {
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
    /// ユーザーのメニューの「ハンドルをコピー」を選んだ。
    func showHandleCopiedNotice()
    /// ユーザーのメニューのメンションとハンドルをコピーを組むもの。nilなら2つの項目を出さない。
    var userMenuActions: UserMenuActions? { get }
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
            let host = nearest((any LinkMenuHost).self)
            let target = UserMenuTarget.profileURL(url, shownAcct: acct)
            let actions = host?.userMenuActions
            let load = actions.map { actions in UserRelationLoad { try await actions.loadRelation(target) } }
            let firstRelationItem = settings.userMenuLayout.groups.firstRelationItem
            children = settings.userMenuLayout.groups.menuElements { item in
                if let action = item.urlAction {
                    return [action.action(url: url, handlers: handlers)]
                }
                switch item {
                case .profile: return [profileAction(item.title, image: item.image, destination)]
                case .mention, .copyHandle: return actions?.action(item, target: target, notifying: host).map { [$0] } ?? []
                case .follow, .showReblogs, .notify, .mute, .block, .report:
                    guard let actions, let load else { return [] }
                    return [actions.relationElement(item, load: load, showsFailure: item == firstRelationItem)]
                // 共通の項目は、上で中身から組んだ。
                case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari: return []
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
