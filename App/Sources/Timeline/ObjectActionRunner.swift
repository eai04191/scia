import SciaCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// メニューを開いている間と閉じたあとに、メニューを出した画面に知らせること。長押しのメニューと同じものを呼ぶ。
@MainActor
struct MenuLifecycle {
    var willShow: () -> Void = {}
    var willEnd: () -> Void = {}
    var didHide: () -> Void = {}
}

/// タップと長押しの操作を選べる対象。設定画面の見出しと、選んだ操作の設定を1か所に持つ。
/// どの部品がどの対象かは、docs/object-actions.mdの「対象」にある。主な操作（タップの既定）は、項目の種類の`primaryItem`で決まる。
struct ObjectEntity<Item: ObjectActionItem & MenuItemPresentable> {
    let title: String
    let actions: ReferenceWritableKeyPath<AppSettings, ObjectActions<Item>>

    /// `trigger`に、主な操作を選んでいるか。主な操作は、呼ぶ側が今のタップの処理で行う。
    @MainActor
    func performsPrimary(_ trigger: ObjectTrigger, settings: AppSettings = AppDependencies.settings) -> Bool {
        settings[keyPath: actions].performsPrimary(trigger)
    }
}

@MainActor
extension ObjectEntity where Item == StatusMenuItem {
    /// 一覧の投稿の行と、引用の囲み。
    static var status: Self { ObjectEntity(title: "投稿", actions: \.statusActions) }
    static var notification: Self { ObjectEntity(title: "通知", actions: \.notificationActions) }
}

@MainActor
extension ObjectEntity where Item == UserMenuItem {
    static var user: Self { ObjectEntity(title: "ユーザー", actions: \.userActions) }
}

@MainActor
extension ObjectEntity where Item == LinkMenuItem {
    static var link: Self { ObjectEntity(title: "リンク", actions: \.linkActions) }
}

/// Xの投稿の囲みのような、Mastodonの外のサービスの投稿。
@MainActor
extension ObjectEntity where Item == ExternalPostMenuItem {
    static var externalPost: Self { ObjectEntity(title: "ほかのサービスの投稿", actions: \.externalPostActions) }
}

@MainActor
extension ObjectEntity where Item == HashtagMenuItem {
    static var hashtag: Self { ObjectEntity(title: "ハッシュタグ", actions: \.hashtagActions) }
}

@MainActor
extension ObjectEntity where Item == MediaMenuItem {
    static var media: Self { ObjectEntity(title: "メディア", actions: \.mediaActions) }
}

/// 押された対象。部品は、タップと長押しをこれに渡す。項目の種類の違う対象を同じ部品で扱えるよう、型を消して持つ。
@MainActor
protocol ObjectActionTarget {
    /// 長押しのメニュー。設定の並びで組む。出す項目がなければnil。
    func menu() -> UIMenu?
    /// タップを受けるか。主な操作がいま行えない部品（スレッドの中心の投稿、投稿のない通知）は、タップに主な操作を選んでいれば、今どおり押せないままにする。
    var acceptsTap: Bool { get }
    /// 長押しにメニュー以外を選び、この部品で行えるか。行えなければ、長押しのメニューを出す。決まりはdocs/object-actions.mdの「長押しで項目を行う」にある。
    func performsLongPress() -> Bool
    /// `trigger`に選んだ操作を行う。`view`は押した部品、`point`はその座標で、メニューはそこに出す。
    func perform(_ trigger: ObjectTrigger, in view: UIView, at point: CGPoint)
    var lifecycle: MenuLifecycle { get }
}

/// 押された対象と、その主な操作の処理と、メニューの組み方。決まりはdocs/object-actions.mdの「項目を行う」にある。
/// タップや長押しに割り当てた1項目をどう行うかは、SciaCoreで組んだメニューの木を見て決める（`MenuItemOutcome`）。
@MainActor
struct ObjectTarget<Item: ObjectActionItem & MenuItemPresentable, Command>: ObjectActionTarget {
    let entity: ObjectEntity<Item>
    var settings: AppSettings = AppDependencies.settings
    /// 主な操作がいま行えるか。
    var primaryIsAvailable = true
    /// 主な操作。今のタップの処理で行う。メニューの項目を組んで行うと、開く動きの起点などがタップと違うため。押した部品を渡す。
    let primary: (UIView) -> Void
    /// 渡した並びでメニューを組む。nilなら設定の並びで組む。出す項目がなければnil。
    let buildMenu: (MenuLayout<Item>.Groups?) -> BuiltMenu<Command>?
    let lifecycle: MenuLifecycle
    /// 使えない項目を選んだことを、数秒で消えるチップで知らせる。
    let notify: (Notice) -> Void

    private var actions: ObjectActions<Item> {
        settings[keyPath: entity.actions]
    }

    func menu() -> UIMenu? {
        buildMenu(nil)?.menu
    }

    var acceptsTap: Bool {
        !actions.performsPrimary(.tap) || primaryIsAvailable
    }

    func performsLongPress() -> Bool {
        guard case .item(let item) = actions.longPress else { return false }
        if item == Item.primaryItem { return primaryIsAvailable }
        return MenuItemOutcome(singleItemMenu: buildMenu(.single(item))?.root).isAvailable
    }

    func perform(_ trigger: ObjectTrigger, in view: UIView, at point: CGPoint) {
        switch actions[trigger] {
        case .menu:
            guard let menu = menu() else { return }
            TapMenuPresenter.shared.present(menu, in: view, at: point, lifecycle: lifecycle)
        case .item(let item):
            if item == Item.primaryItem {
                // 主な操作がいま行えない部品では何もしない。呼ぶ側の処理が、行えるかを確かめる。
                primary(view)
                return
            }
            // その対象のメニューと同じ組み方で、`item`だけを組む。
            let built = buildMenu(.single(item))
            switch MenuItemOutcome(singleItemMenu: built?.root) {
            case .perform(let command):
                TapMenuPresenter.shared.perform(in: view, at: point) { built?.renderer.perform(command) }
            case .unavailable(let reason):
                notify(unavailable(item, reason: reason))
            case .submenu(let submenu):
                // サブメニューの名前だけの1行のメニューを出すと、もう1回押さないと中身に届かないため、中身を出す。
                guard let built else { return }
                TapMenuPresenter.shared.present(UIMenu(title: submenu.title, subtitle: submenu.subtitle, children: built.elements(submenu.children)), in: view, at: point, lifecycle: lifecycle)
            case .menu(let nodes):
                guard let built else { return }
                TapMenuPresenter.shared.present(UIMenu(children: built.elements(nodes)), in: view, at: point, lifecycle: lifecycle)
            }
        }
    }

    /// 使えない項目を選んだことの知らせ。押せない理由があれば、それを文言にする。
    private func unavailable(_ item: Item, reason: String?) -> Notice {
        .objectActionUnavailable(itemTitle: item.title, reason: reason)
    }
}

/// タップでメニューを出す。
///
/// `UIContextMenuInteraction`には、コードからメニューを出す公開APIがない。押した位置に1ptの見えない`UIButton`を置き、
/// `showsMenuAsPrimaryAction`にして`performPrimaryAction()`（iOS 17.4）を送る。`UIControl`では、`performPrimaryAction()`を送ってもメニューが出ない。
/// ボタンは触れたタッチを受けないので、スクロールや部品のタップを奪わない。
@MainActor
final class TapMenuPresenter {
    static let shared = TapMenuPresenter()

    private let button = AnchorMenuButton()

    private init() {
        button.showsMenuAsPrimaryAction = true
        button.isUserInteractionEnabled = false
        // ボタンのメニューは、上へ開くと項目の順を逆にする。長押しのメニューと同じ順に並べる。
        button.preferredMenuElementOrder = .fixed
    }

    /// メニューだけを押した位置に出す。行や画像は持ち上げない。
    /// ボタンから出すメニューは、構成のプレビュー（`previewProvider`）を描かない。長押しの持ち上げるプレビューを渡すと、元の場所は隠されるのに
    /// プレビューが描かれず、本文の行やサムネイルが消えて見えたため、いつも指の位置の見えない目印をプレビューにする。
    func present(_ menu: UIMenu, in view: UIView, at point: CGPoint, lifecycle: MenuLifecycle) {
        guard place(in: view, at: point) else { return }
        button.menu = menu
        button.lifecycle = lifecycle
        button.performPrimaryAction()
    }

    /// メニューの項目を、メニューを出さずに行う。メニューを出せる画面の中の部品でだけ行う。
    func perform(in view: UIView, at point: CGPoint, _ body: () -> Void) {
        guard place(in: view, at: point) else { return }
        body()
    }

    /// 押した部品から一番近い画面のviewに置く。ウインドウの直下に置くと、応答の連鎖にメニューを出す画面がなく、メニューが出ない。
    private func place(in view: UIView, at point: CGPoint) -> Bool {
        let controller = sequence(first: view as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
        guard let container = controller?.view else { return false }
        if button.superview !== container {
            container.addSubview(button)
        }
        let location = view.convert(point, to: container)
        button.frame = CGRect(x: location.x, y: location.y, width: 1, height: 1)
        return true
    }
}

private final class AnchorMenuButton: UIButton {
    var lifecycle = MenuLifecycle()

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        anchorPreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        anchorPreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        lifecycle.willShow()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        // 閉じ終わる前に別のメニューを出しても、閉じたほうの知らせを取り違えないよう、閉じ始めに決めておく。
        // ボタンはアプリで1つなので、閉じた画面とメニューの中身を次に開くまで握らないよう、ここで手放す。
        let lifecycle = lifecycle
        self.lifecycle = MenuLifecycle()
        menu = nil
        lifecycle.willEnd()
        guard let animator else {
            lifecycle.didHide()
            return
        }
        animator.addCompletion { lifecycle.didHide() }
    }

    /// 指の位置の見えない目印をプレビューにして、メニューだけを指の位置に出す。
    private func anchorPreview() -> UITargetedPreview? {
        guard let container = superview else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UITargetedPreview(view: anchor, parameters: parameters, target: UIPreviewTarget(container: container, center: center))
    }
}

/// 対象の長押しにメニュー以外を選んだときに、長押しを受ける。決まりはdocs/object-actions.mdの「長押しで項目を行う」にある。
/// 長押しと認める長さは、UIKitの長押しのジェスチャーの既定のままにする。
/// リンクやサムネイルのような、自分でタップや長押しを受ける部品の上では受けず、その部品の対象の設定に任せる。
@MainActor
final class ObjectLongPress: NSObject, UIGestureRecognizerDelegate {
    private let recognizer = UILongPressGestureRecognizer()
    /// 押した位置（`view`の座標）で、長押しを受けるか。
    private let accepts: (CGPoint) -> Bool
    private let perform: (CGPoint) -> Void
    init(on view: UIView, accepts: @escaping (CGPoint) -> Bool, perform: @escaping (CGPoint) -> Void) {
        self.accepts = accepts
        self.perform = perform
        super.init()
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handle(_:)))
        view.addGestureRecognizer(recognizer)
    }

    @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view = gesture.view else { return }
        let location = gesture.location(in: view)
        let intensity = AppDependencies.tuning.value(of: TuningCatalog.objectLongPressHapticIntensity)
        if intensity > 0 {
            UIImpactFeedbackGenerator(style: .medium, view: view).impactOccurred(intensity: intensity, at: location)
        }
        perform(location)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        return accepts(gestureRecognizer.location(in: view))
    }

    /// 触れた先から`view`までの間に、自分でタップや長押しを受ける部品（`UIControl`か、長押しのメニューを持つもの）があれば受けない。
    /// `view`そのものは数えないので、リンクやサムネイルのような部品そのものに付けても、その部品の上で受ける。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== gestureRecognizer.view {
            if current is UIControl || current.interactions.contains(where: { $0 is UIContextMenuInteraction }) { return false }
            view = current.superview
        }
        return true
    }
}

/// 長押しのメニューを出すときに、部品をどう持ち上げるか。決まりはdocs/menus.mdの「持ち上げ方」にある。
enum ObjectLift {
    /// 持ち上げず、一覧の行と同じく指の位置にメニューだけを出す。
    /// 文字の行（通知の見出し、「〜がブースト」の行）も、行と同じく閉じるときに文字がゆがむため、持ち上げない。
    case none
    /// 部品を今の角丸の形のまま持ち上げる（アイコン）。
    case shape
}

/// 自分ではタップも長押しも受けない部品（アイコン、引用の囲みなど）に、対象のタップと長押しを付ける。
@MainActor
final class ObjectInteraction: NSObject, UIContextMenuInteractionDelegate {
    private weak var view: UIView?
    private let lift: ObjectLift
    var target: (any ObjectActionTarget)?
    private var longPress: ObjectLongPress?
    /// 部品がボタンのように自分でタップを受けるとき、その処理は押した位置を受け取らないため、触れた位置を覚えてメニューを出す位置にする。
    private let touchRecorder = TouchLocationRecorder()

    /// - Parameter tapsSelf: 部品のタップもここで受ける。部品がボタンのように自分でタップを受けるなら、falseにしてその処理から`handleTap(at:)`を呼ぶ。
    init(on view: UIView, tapsSelf: Bool, lift: ObjectLift = .none) {
        self.view = view
        self.lift = lift
        super.init()
        view.isUserInteractionEnabled = true
        view.addInteraction(UIContextMenuInteraction(delegate: self))
        if tapsSelf {
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        } else {
            touchRecorder.cancelsTouchesInView = false
            touchRecorder.delaysTouchesEnded = false
            view.addGestureRecognizer(touchRecorder)
        }
        longPress = ObjectLongPress(on: view, accepts: { [weak self] _ in
            self?.target?.performsLongPress() ?? false
        }, perform: { [weak self] point in
            guard let self, let view = self.view else { return }
            target?.perform(.longPress, in: view, at: point)
        })
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        handleTap(at: gesture.location(in: gesture.view))
    }

    func handleTap(at point: CGPoint) {
        guard let view else { return }
        target?.perform(.tap, in: view, at: point)
    }

    /// 部品が自分で受けたタップを、最後に触れた位置で行う。
    func handleTap() {
        guard let view else { return }
        handleTap(at: touchRecorder.lastLocation ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let target, !target.performsLongPress(), let menu = target.menu() else { return nil }
        return UIContextMenuConfiguration(identifier: NSValue(cgPoint: location), previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview(for: configuration)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        target?.lifecycle.willShow()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        // 閉じ終わる前に部品が別の対象に使い回されても、閉じたほうの知らせを取り違えないよう、閉じ始めに決めておく。
        guard let lifecycle = target?.lifecycle else { return }
        lifecycle.willEnd()
        guard let animator else {
            lifecycle.didHide()
            return
        }
        animator.addCompletion { lifecycle.didHide() }
    }

    private func preview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        switch lift {
        case .none:
            return anchorPreview(for: configuration)
        case .shape:
            guard let view, view.window != nil else { return nil }
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: view.layer.cornerRadius)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }

    /// 指の位置の見えない目印をプレビューにして、メニューだけを指の位置に出す。
    private func anchorPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let view, let point = (configuration.identifier as? NSValue)?.cgPointValue else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UITargetedPreview(view: anchor, parameters: parameters, target: UIPreviewTarget(container: view, center: point))
    }
}

/// 触れた位置を覚えるだけで、認識しない。一覧の行のタップのように、タップの処理が押した位置を受け取らないときに、メニューを出す位置にする。
final class TouchLocationRecorder: UIGestureRecognizer {
    private(set) var lastLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        lastLocation = touches.first?.location(in: view)
        state = .failed
    }
}
