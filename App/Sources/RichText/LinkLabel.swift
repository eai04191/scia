import SciaCore
import UIKit

/// RichTextRendererで描いた本文の、リンクの部分をタップできるラベル。リンクの外のタップは受けず、セルなど後ろのビューに渡す。
final class LinkLabel: EmojiLabel {
    /// 長押しのメニューの並び。
    var settings: AppSettings = AppDependencies.settings

    /// リンクがタップされたときと、メンションの長押しのメニューでプロフィールを、ハッシュタグの長押しのメニューでタイムラインを選んだときに、その行き先を渡して呼ぶ。
    var onTapLink: ((RichText.LinkDestination) -> Void)?
    /// ハッシュタグのメニューの「ユーザーの投稿」で開くユーザー。投稿の本文なら投稿した人、プロフィールならその人。nilなら項目を出さない。
    var hashtagAccount: Account?

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

    fileprivate func open(_ destination: RichText.LinkDestination) {
        onTapLink?(destination)
    }

    /// 本文のリンクを、文字と行き先の組で順に返す。書式で分かれた同じリンクはつなげる。
    static func links(in body: NSAttributedString) -> [(text: String, destination: RichText.LinkDestination)] {
        var result: [(text: String, destination: RichText.LinkDestination, end: Int)] = []
        body.enumerateAttribute(.linkDestination, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let destination = value as? RichText.LinkDestination else { return }
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

}



/// `LinkHitArea`の長押しのメニューを出す。コントロール自身を委譲先にすると、組み込まれたメニューの処理と混ざるため、別のものにする。
@MainActor
private final class LinkMenuInteraction: NSObject, UIContextMenuInteractionDelegate {
    private weak var hitArea: LinkHitArea?

    init(hitArea: LinkHitArea) {
        self.hitArea = hitArea
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        hitArea?.menuConfiguration(at: location)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        hitArea?.linkPreview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        hitArea?.linkPreview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        hitArea?.menuWillShow()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        hitArea?.menuWillEnd(animator: animator)
    }
}

/// 本文のリンクのメニューを、タップや長押しに割り当てた1項目だけで組むときの並び。行き先の対象ごとに、項目の種類が違う。
enum LinkMenuGroups {
    case link(MenuLayout<LinkMenuItem>.Groups)
    case user(MenuLayout<UserMenuItem>.Groups)
    case hashtag(MenuLayout<HashtagMenuItem>.Groups)

    var link: MenuLayout<LinkMenuItem>.Groups? {
        if case .link(let groups) = self { groups } else { nil }
    }

    var user: MenuLayout<UserMenuItem>.Groups? {
        if case .user(let groups) = self { groups } else { nil }
    }

    var hashtag: MenuLayout<HashtagMenuItem>.Groups? {
        if case .hashtag(let groups) = self { groups } else { nil }
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
    /// タップや長押しに選んだ項目が使えないことなどを、数秒で消えるチップで知らせる。
    func showNotice(_ notice: Notice)
    /// ユーザーのメニューの「ハンドルをコピー」を選んだ。
    func showHandleCopiedNotice()
    /// ユーザーのメニューのメンションとハンドルをコピーを組むもの。nilなら2つの項目を出さない。
    var userMenuActions: UserMenuActions? { get }
    /// ハッシュタグのメニューのミュートを組むもの。nilなら項目を出さない。
    var hashtagMuteActions: HashtagMuteActions? { get }
    /// 開く項目を選んだ。`browser`は選んだ項目と開く場所の設定から決めた、実際に開く場所。
    func openURL(_ url: URL, in browser: LinkBrowser)
    /// リンクのメニューの「プロフィールとして開く」を選んだ。
    func openProfile(resolving url: URL)
    /// ハッシュタグのメニューの「ユーザーの投稿」を選んだ。`name`は`#`を除いた名前。
    func openHashtag(_ name: String, of account: Account)
    /// 本文のメンションのメニューの「プロフィール」に出す、その人のアイコン。`url`はメンションのリンク先。
    /// 誰か分からなければnilで、項目の記号のままにする。アイコンがまだなければプレースホルダーのアイコンを返し、届いたら開いているメニューで差し替える。
    func mentionMenuIcon(for url: URL) -> UIImage?
}

/// `LinkLabel`の上に重ねる、リンクの上だけを当たりにする部品。リンクの外では当たりにならず、押下はラベルの後ろのセルへ渡る。
/// スクロールビューは標準では`UIControl`の上で始まった押下をスクロールに切り替えないため、載せるスクロールビューは`touchesShouldCancel(in:)`でこの部品にtrueを返す。
/// リンクの上の長押しは、セルの後ろのコレクションビューに渡らず投稿のメニューにならないため、この部品でリンクのメニューを出す。
/// メニューは、コントロールに組み込まれたメニュー（`isContextMenuInteractionEnabled`）ではなく、別に付けた`UIContextMenuInteraction`で出す。
/// 組み込まれたメニューでは、長押しで開いても触覚フィードバックが出ないため。
final class LinkHitArea: UIControl {
    private weak var label: LinkLabel?
    private var longPress: ObjectLongPress?
    private lazy var menuInteraction = LinkMenuInteraction(hitArea: self)

    init(label: LinkLabel) {
        self.label = label
        super.init(frame: .zero)
        isAccessibilityElement = false
        addInteraction(UIContextMenuInteraction(delegate: menuInteraction))
        installLongPress()
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
        guard let touch, isTouchInside else { return }
        let point = touch.location(in: self)
        target(at: point)?.perform(.tap, in: self, at: point)
    }

    /// 押したリンクの行き先の対象（リンク、ユーザー、ハッシュタグ）。リンクの外ならnil。決まりはdocs/object-actions.mdにある。
    /// 主な操作（開く）は、今のタップの処理のまま行う。
    private func target(at point: CGPoint) -> (any ObjectActionTarget)? {
        guard let label, let destination = label.link(at: convert(point, to: label)) else { return nil }
        let host = nearest((any LinkMenuHost).self)
        let lifecycle = MenuLifecycle(willShow: { host?.linkMenuWillShow() }, didHide: { host?.linkMenuDidHide() })
        let notify: (Notice) -> Void = { host?.showNotice($0) }
        let open: (UIView) -> Void = { [weak label] _ in label?.open(destination) }
        switch destination {
        case .url(let url):
            return ObjectTarget(entity: .link, settings: label.settings, primary: open, buildMenu: { [weak self] in
                self?.linkMenu(for: url, at: point, groups: $0)
            }, lifecycle: lifecycle, notify: notify)
        case .mention(let acct, let url):
            return ObjectTarget(entity: .user, settings: label.settings, primary: open, buildMenu: { [weak self] in
                self?.userMenu(for: destination, acct: acct, url: url, at: point, groups: $0)
            }, lifecycle: lifecycle, notify: notify)
        case .hashtag(let name, let url):
            return ObjectTarget(entity: .hashtag, settings: label.settings, primary: open, buildMenu: { [weak self] in
                self?.hashtagMenu(for: destination, name: name, url: url, at: point, groups: $0)
            }, lifecycle: lifecycle, notify: notify)
        }
    }

    /// 長押しにメニュー以外を選んだときに、リンクの上の長押しを受ける。
    func installLongPress() {
        longPress = ObjectLongPress(on: self, accepts: { [weak self] point in
            self?.target(at: point)?.performsLongPress() ?? false
        }, perform: { [weak self] point in
            guard let self else { return }
            target(at: point)?.perform(.longPress, in: self, at: point)
        })
    }

    /// 長押しのメニューの構成。リンクの外か、出す項目をすべて隠していればnil。
    fileprivate func menuConfiguration(at location: CGPoint) -> UIContextMenuConfiguration? {
        guard let label, target(at: location)?.performsLongPress() != true else { return nil }
        let point = convert(location, to: label)
        // 出す項目をすべて隠していれば、メニューを出さない。
        guard let destination = label.link(at: point), let menu = menu(for: destination, at: point) else { return nil }
        // 浮かせるリンクを選び直せるよう、押した場所をidentifierに持たせる。
        return UIContextMenuConfiguration(identifier: NSValue(cgPoint: point), previewProvider: nil) { _ in menu }
    }

    fileprivate func menuWillShow() {
        nearest((any LinkMenuHost).self)?.linkMenuWillShow()
    }

    /// 閉じるアニメーションの間も行を動かさない。
    fileprivate func menuWillEnd(animator: (any UIContextMenuInteractionAnimating)?) {
        // 閉じ終わる前にセルが使い回されてもよいよう、知らせる先は閉じ始めに決めておく。
        let host = nearest((any LinkMenuHost).self)
        guard let animator else {
            host?.linkMenuDidHide()
            return
        }
        animator.addCompletion { host?.linkMenuDidHide() }
    }

    /// 押したリンクの文字だけを浮かせる。部品はラベルと同じ大きさで透明なため、そのままでは本文の全体が浮く。
    /// ラベルそのものを渡すと、UIKitがメニューを出している間ラベルを隠し、浮かせたリンクのほかの本文が消えるため、ラベルのスナップショットを浮かせる。
    /// スナップショットは、リンクの文字の枠でちょうど切り抜く。浮かせる面はリンクの枠より余白の分広く、切り抜かないと隣の文字まで面に写り、元の本文と二重に見えるため。
    /// スナップショットは画面に置かないので、開き始めの約3コマは本文に残ったリンクと浮かせた面が二重に見え、閉じた直後の約3コマはリンクの両隣の文字が欠ける。
    /// リンクだけを写したビューをリンクの真上に置き、ラベルからリンクの部分を抜いてそのビューを浮かせると、開閉の両端はずれなくなる。
    /// ただ、メニューを出す前に指を動かして取りやめると、UIKitは置いたビューを隠したまま縮めて戻し、面にも中身を写さないので、約0.4秒リンクの場所が空白になる。
    /// 公開APIでは取りやめの間にビューを見せ直せないため、取りやめでも文字が見えたままのこちらを選んだ。
    fileprivate func linkPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let label, let point = (configuration.identifier as? NSValue)?.cgPointValue else { return nil }
        let frames = label.linkFrames(at: point)
        guard !frames.isEmpty, let snapshot = label.snapshotView(afterScreenUpdates: false) else { return nil }
        let linkOnly = UIView(frame: label.bounds)
        linkOnly.addSubview(snapshot)
        let mask = CAShapeLayer()
        let path = UIBezierPath()
        frames.forEach { path.append(UIBezierPath(rect: $0)) }
        mask.path = path.cgPath
        linkOnly.layer.mask = mask
        // UIKitは、浮かせる面（リンクの枠）の中央をtargetの中央に置く。ラベルの中央を渡すと、面がリンクの位置からずれて出る。
        let linkBounds = frames.reduce(CGRect.null) { $0.union($1) }
        let target = UIPreviewTarget(container: label, center: CGPoint(x: linkBounds.midX, y: linkBounds.midY))
        return UITargetedPreview(view: linkOnly, parameters: UIPreviewParameters(textLineRects: frames.map { NSValue(cgRect: $0) }), target: target)
    }

    /// 並びは設定のリンクのメニューとハッシュタグのメニューに従う。メンションはユーザーなので、ユーザーのメニューで出す。出す項目がなければnil。
    /// 開く項目は、メニューを出した画面に開く場所を渡して開かせる。アプリ内のSafariはセッションが持つため、ラベルからは開けない。
    /// - Parameter groups: 組む並び。省略すると設定の並びで組む。タップや長押しに割り当てた1項目だけを組むときに渡す。行き先の対象と違う並びは使わない。
    func menu(for destination: RichText.LinkDestination, at point: CGPoint, groups: LinkMenuGroups? = nil) -> UIMenu? {
        switch destination {
        case .url(let url):
            linkMenu(for: url, at: point, groups: groups?.link)?.menu
        case .mention(let acct, let url):
            userMenu(for: destination, acct: acct, url: url, at: point, groups: groups?.user)?.menu
        case .hashtag(let name, let url):
            hashtagMenu(for: destination, name: name, url: url, at: point, groups: groups?.hashtag)?.menu
        }
    }

    private func linkMenu(for url: URL, at point: CGPoint, groups: MenuLayout<LinkMenuItem>.Groups?) -> BuiltMenu<LinkMenuCommand>? {
        guard let label else { return nil }
        let settings = label.settings
        let menu = LinkMenu(url: url, handlers: urlHandlers(at: point, linkBrowser: settings.linkBrowser)) { [weak self] in
            self?.nearest((any LinkMenuHost).self)?.openProfile(resolving: url)
        }
        return menu.built(groups: groups ?? settings.linkMenuLayout.groups)
    }

    private func userMenu(for destination: RichText.LinkDestination, acct: String, url: URL, at point: CGPoint, groups: MenuLayout<UserMenuItem>.Groups?) -> BuiltMenu<UserMenuCommand>? {
        guard let label else { return nil }
        let settings = label.settings
        let host = nearest((any LinkMenuHost).self)
        let menu = UserMenu(subject: UserMenuSubject(mentionLink: url, acct: acct), actions: host?.userMenuActions, handlers: urlHandlers(at: point, linkBrowser: settings.linkBrowser), host: host)
        return menu.built(groups: groups ?? settings.userMenuLayout.groups, openProfile: { [weak self] in self?.label?.open(destination) }, avatar: .mentionLink(url)) { _ in
            host?.mentionMenuIcon(for: url)
        }
    }

    private func hashtagMenu(for destination: RichText.LinkDestination, name: String, url: URL?, at point: CGPoint, groups: MenuLayout<HashtagMenuItem>.Groups?) -> BuiltMenu<HashtagMenuCommand>? {
        guard let label else { return nil }
        let settings = label.settings
        let menu = HashtagMenu(
            name: name,
            url: url,
            account: label.hashtagAccount,
            handlers: urlHandlers(at: point, linkBrowser: settings.linkBrowser),
            muteActions: nearest((any LinkMenuHost).self)?.hashtagMuteActions,
            openTimeline: { [weak self] in self?.label?.open(destination) },
            openAccountStatuses: { [weak self] account in self?.nearest((any LinkMenuHost).self)?.openHashtag(name, of: account) }
        )
        return menu.built(groups: groups ?? settings.hashtagMenuLayout.groups)
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
