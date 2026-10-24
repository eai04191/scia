import SciaCore
import UIKit

extension MediaMenuItem: MenuItemContentProviding {
    var content: MenuItemContent {
        switch self {
        case .open: .own(title: "開く", symbolName: "arrow.up.left.and.arrow.down.right", note: "ビューアでは出ません")
        case .share: .own(title: "共有", symbolName: "square.and.arrow.up", note: "メディアのファイルを共有します")
        case .saveToPhotos: .own(title: "写真に保存", symbolName: "square.and.arrow.down", note: "画像、動画、GIFでだけ出ます")
        case .altText: .own(title: "代替テキスト", symbolName: "text.below.photo", note: "代替テキストが付いているときだけ出ます")
        case .translateText: .own(title: "画像の文字を翻訳", symbolName: "translate", note: "ビューアで画像から文字を読み取れたときだけ出ます")
        case .copyLink: .url(.copyLink, noteSuffix: "メディアのファイルのURLをコピーします")
        case .openInBrowser: .url(.openInBrowser, noteSuffix: "メディアのファイルを開きます")
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .status: .own(title: "投稿", symbolName: "text.bubble", note: "投稿のメニューをサブメニューで出します。ビューアとプロフィールの画像では出ません")
        case .info: .own(title: "メディアの情報", symbolName: "info.circle", note: "解像度、形式、フレームレート、長さ、ビットレートのうち分かるものを出します")
        }
    }
}

/// メディアのメニュー。一覧とビューアで、設定の同じ並びから組む。決まりはdocs/menus.mdの「メディアのメニュー」にある。
/// 項目ごとの動きは置く側で渡し、渡さなかった項目は出さない。
@MainActor
struct MediaMenu {
    /// 押せるかどうかと、押したときの動き。ビューアでは、元のファイルが届くまで共有と保存を押せなくする。
    struct Command {
        var isEnabled = true
        let perform: @MainActor () -> Void
    }

    let kind: MediaAttachment.Kind
    /// 代替テキストを見せる項目と、メディアの情報を組むのに使う。手元のファイルを開いたビューアではnil。
    let attachment: MediaAttachment?
    var open: Command?
    var share: Command?
    var saveToPhotos: Command?
    var showAltText: Command?
    var translateText: Command?
    /// リンクのコピーと開く項目で扱う、ファイルのURL。
    var fileURL: URL?
    /// リンクのコピーと開く項目の動き。nilなら、URLの項目を出さない。
    var urlHandlers: URLMenuHandlers?
    /// 開く項目を出すか。開く先のないビューア（Macの別のウィンドウや編集履歴から開いたとき）では、リンクのコピーだけを出す。
    var opensURLs = true
    /// ビューアでファイルの中身から読んだ値。メディアの情報を詳しくする。一覧ではnil。
    var details: MediaFileDetails?
    /// 投稿の投稿のメニュー。サブメニューにして出す。
    var statusMenu: UIMenu?
    /// メディアの情報の行を押したときに、その値をコピーする。
    var copyValue: (@MainActor (String) -> Void)?

    init(kind: MediaAttachment.Kind, attachment: MediaAttachment?) {
        self.kind = kind
        self.attachment = attachment
    }

    /// 出す項目がなければ空。
    func elements(layout: MenuLayout<MediaMenuItem>) -> [UIMenuElement] {
        layout.groups.menuElements { item in element(for: item).map { [$0] } ?? [] }
    }

    /// 見出しは置かない。長押ししたサムネイルを持ち上げて見せるので、何のメニューかは見れば分かるため。出す項目がなければnil。
    func menu(layout: MenuLayout<MediaMenuItem>) -> UIMenu? {
        let children = elements(layout: layout)
        guard !children.isEmpty else { return nil }
        return UIMenu(children: children)
    }

    private func element(for item: MediaMenuItem) -> UIMenuElement? {
        if let action = item.urlAction {
            guard let urlHandlers, action == .copyLink || opensURLs else { return nil }
            return action.action(url: fileURL, handlers: urlHandlers)
        }
        switch item {
        case .open:
            return open.map { action(item, $0) }
        case .share:
            return share.map { action(item, $0) }
        case .saveToPhotos:
            guard [.image, .video, .gifv].contains(kind) else { return nil }
            return saveToPhotos.map { action(item, $0) }
        case .altText:
            guard let description = attachment?.description, !description.isEmpty else { return nil }
            return showAltText.map { action(item, $0) }
        case .translateText:
            return translateText.map { action(item, $0) }
        case .status:
            guard let statusMenu else { return nil }
            return UIMenu(title: item.title, image: item.image, children: statusMenu.children)
        case .info:
            return infoMenu(item)
        case .copyLink, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            // 共通の項目は、上で中身から組んだ。
            return nil
        }
    }

    private func action(_ item: MediaMenuItem, _ command: Command) -> UIAction {
        UIAction(title: item.title, image: item.image, attributes: command.isEnabled ? [] : .disabled) { _ in command.perform() }
    }

    /// 値を名前にし、何の値かをサブタイトルに置いて、値を読みやすくする。押すと値をコピーする。
    private func infoMenu(_ item: MediaMenuItem) -> UIMenu? {
        guard let attachment else { return nil }
        let lines = MediaInfo(attachment, details: details).lines
        guard !lines.isEmpty else { return nil }
        return UIMenu(title: item.title, image: item.image, children: lines.map { line in
            UIAction(title: line.value, subtitle: line.label) { [copyValue] _ in copyValue?(line.value) }
        })
    }
}

/// サムネイルやリンクカードの画像を長押ししたときに、メディアのメニューを組む画面。
/// どちらもボタンの中にあり、一覧の行の長押しのメニューが届かないため、長押しされたビューが自分で受け、応答の連鎖をたどって見つけた画面に問い合わせる。
/// 見つからない画面（編集履歴など）では、メニューを出さない。
@MainActor
protocol MediaMenuHost: AnyObject {
    /// `view`の`location`（`view`の座標）を長押しした。出すものがなければnil。
    func mediaMenu(from view: UIView, at location: CGPoint) -> UIMenu?
    func mediaMenuWillShow()
    func mediaMenuDidHide()
}

/// サムネイル、リンクカードの画像、プロフィールの画像に付ける、メディアのメニューの長押し。
/// ボタンに組み込まれた長押しのメニュー（`isContextMenuInteractionEnabled`）は、ボタンがメニューに変形する形で出るため、押した画像が消え、触覚フィードバックもない。
/// そこでボタンとは別に付け、プロフィールのアイコンと同じく、画像を持ち上げてメニューを出す。
///
/// 持ち上げるときは、サムネイルの切り抜きではなく画像の全体を見せる。保存や共有の前に、どの画像かを確かめられるようにするため。
/// アイコンは画像を切り抜いておらず、丸や角丸四角の形も見た目の一部なので、ビューそのものを今の形のまま持ち上げる。
/// UIKitのプレビューは角を決まった大きさで丸めるため、小さなアイコンに使うと形が変わりすぎる。
/// 画像の全体はUIKitのプレビューとして渡し、持ち上げる元と閉じて戻る先にはサムネイル自身を渡す。UIKitが、切り抜いたサムネイルから画像の全体へ変形して持ち上げ、
/// 閉じると元の形へ戻し、その間のサムネイルの出し入れも受け持つ。別のビューに描いてサムネイルを自分で透明にすると、UIKitの出し入れと間合いがずれ、
/// 押し始めや閉じたあとにサムネイルの場所が白く抜けたため。
@MainActor
final class MediaMenuInteraction: NSObject, UIContextMenuInteractionDelegate {
    private weak var view: UIView?
    /// 長押しした場所（`view`の座標）でメニューを出すか。
    private let offersMenu: @MainActor (CGPoint) -> Bool
    /// 持ち上げるときに見せる画像の全体。読み込む前ならnilを返し、サムネイルをそのまま持ち上げる。
    /// 渡さなければ、いつもビューそのものを今の形のまま持ち上げる（アイコン）。
    private let wholeImage: (@MainActor () -> UIImage?)?
    /// 持ち上げた画像をタップしたときに、タップしたときと同じくビューアで開く。
    private let open: @MainActor () -> Void
    /// メニューを組む。nilなら、応答の連鎖で見つけた`MediaMenuHost`に問い合わせる（一覧の行の中のサムネイル）。
    private let menu: (@MainActor () -> UIMenu?)?
    /// 持ち上げた画像を、渡したピクセル数の長い辺で読み直す。読めなければnil。
    /// サムネイルは表示の大きさに合わせて縮めて読んでいるため、画面の幅に引き伸ばすとぼやける。届いたらプレビューの中で差し替える。
    private let sharperImage: (@MainActor (_ maxPixelSize: Int) async -> UIImage?)?
    /// 持ち上げ始めたときにtrue、メニューを閉じ終えたときにfalseで呼ぶ。UIKitは持ち上げる間、元の場所からビューを隠すため、
    /// その場所が抜けて見えないよう、隠すビューを出したり外したりする（プロフィールのヘッダー画像）。
    /// 持ち上げた画像をタップしてビューアを開いたときは、ビューアが隠すビューの出し入れを受け持つため、falseでは呼ばない。
    private let onLiftChange: (@MainActor (Bool) -> Void)?
    /// 持ち上げた画像をタップして、ビューアを開いた。閉じ終えても`onLiftChange`を呼ばない。
    private var isOpeningViewer = false

    /// - Parameter menu: 一覧の行の外にある画像（プロフィールの画像）のメニュー。
    init(
        on view: UIView,
        wholeImage: (@MainActor () -> UIImage?)?,
        open: @escaping @MainActor () -> Void,
        menu: (@MainActor () -> UIMenu?)? = nil,
        sharperImage: (@MainActor (_ maxPixelSize: Int) async -> UIImage?)? = nil,
        onLiftChange: (@MainActor (Bool) -> Void)? = nil,
        offersMenu: @escaping @MainActor (CGPoint) -> Bool
    ) {
        self.onLiftChange = onLiftChange
        self.view = view
        self.wholeImage = wholeImage
        self.open = open
        self.menu = menu
        self.sharperImage = sharperImage
        self.offersMenu = offersMenu
        super.init()
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let view, offersMenu(location), let menu = menu.map({ $0() }) ?? host?.mediaMenu(from: view, at: location) else { return nil }
        let preview = wholeImagePreview()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: preview.map { controller in { controller } }) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        isOpeningViewer = false
        onLiftChange?(true)
        return thumbnailPreview
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        thumbnailPreview
    }

    /// 持ち上げた画像をタップしたら、メニューを閉じてビューアで開く。
    /// 持ち上げた画像を元の位置へ戻さず、その場で消す（`.pop`）。戻す（`.dismiss`）と、持ち上げた画像がいったん元の位置へ下がってから、
    /// ビューアが開いて見える。UIKitは閉じる動きを終えるまでビューアの表示を待たせるため、開き始めを早めるだけでは下がる動きが残った。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: any UIContextMenuInteractionCommitAnimating) {
        animator.preferredCommitStyle = .pop
        isOpeningViewer = true
        animator.addAnimations { [open] in open() }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        host?.mediaMenuWillShow()
    }

    /// 閉じるアニメーションの間も、一覧の行を動かさない。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        let host = host
        guard let animator else {
            endLift()
            host?.mediaMenuDidHide()
            return
        }
        animator.addCompletion { [weak self] in
            self?.endLift()
            host?.mediaMenuDidHide()
        }
    }

    private func endLift() {
        if !isOpeningViewer {
            onLiftChange?(false)
        }
        isOpeningViewer = false
    }

    private var host: (any MediaMenuHost)? {
        var responder = view?.next
        while let current = responder {
            if let host = current as? any MediaMenuHost { return host }
            responder = current.next
        }
        return nil
    }

    /// 画像の全体を描くプレビュー。画像を読み込む前や画面から外れていればnilにし、サムネイルをそのまま持ち上げる。
    /// 表示しているサムネイルが小さくても、画面の幅に合わせて大きく見せる。縦に収まらなければ、UIKitが縦横比を保って縮める。
    /// サムネイルの大きさを基準にすると、小さいサムネイルは小さく持ち上がり、UIKitがプレビューの角を決まった大きさで丸めるため、カプセルの形に見えた。
    /// 大きさを渡さないと、UIKitは使える高さいっぱいの入れ物を取り、画像の上下に見えない余白ができてメニューが離れるため、縦横比を伝える。
    private func wholeImagePreview() -> UIViewController? {
        guard let view, let window = view.window, let image = wholeImage?(), image.size.width > 0, image.size.height > 0 else { return nil }
        let controller = UIViewController()
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        controller.view = imageView
        let width = window.bounds.width
        let size = CGSize(width: width, height: width * image.size.height / image.size.width)
        controller.preferredContentSize = size
        if let sharperImage {
            let maxPixelSize = Self.sharperPixelSize(previewSize: size, within: window.bounds.size, scale: window.screen.scale)
            Task { [weak imageView] in
                guard let sharper = await sharperImage(maxPixelSize) else { return }
                imageView?.image = sharper
            }
        }
        return controller
    }

    /// 持ち上げた画像を読み直す、長い辺のピクセル数。渡した大きさが縦に収まらなければUIKitが縮めるため、画面に収まる大きさで計算し、
    /// ビューアと同じ上限を超えない。渡した大きさのまま計算すると、縦に長い画像ほど、表示に要らない大きさで展開してしまう。
    static func sharperPixelSize(previewSize: CGSize, within bounds: CGSize, scale: CGFloat) -> Int {
        guard previewSize.width > 0, previewSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 0 }
        let fit = min(1, bounds.width / previewSize.width, bounds.height / previewSize.height)
        let pixels = Int(ceil(max(previewSize.width, previewSize.height) * fit * scale))
        return min(pixels, MediaImageStore.fullPixelSize)
    }

    /// 角を丸めたまま、サムネイルを持ち上げる元と戻る先にする。画面から外れていれば、UIKitに任せる。
    private var thumbnailPreview: UITargetedPreview? {
        guard let view, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: view.layer.cornerRadius)
        return UITargetedPreview(view: view, parameters: parameters)
    }
}
