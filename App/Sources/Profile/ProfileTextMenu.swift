import SciaCore
import UIKit

extension TimelineViewController {
    /// プロフィールの表示名、自己紹介、補足情報の行を長押ししたときのメニュー。決まりはdocs/menus.mdの「プロフィールの文章のメニュー」にある。
    /// 見出しは置かない。押した文章を持ち上げて見せるため。出す項目がなければnil。
    func profileTextMenu(for text: ProfileText) -> UIMenu? {
        let children = settings.profileTextMenuLayout.groups.menuElements { item in
            switch item {
            case .copyText:
                guard let plain = text.text else { return [] }
                return [UIAction(title: item.title, image: item.image) { [weak self] _ in
                    UIPasteboard.general.string = plain
                    guard let self else { return }
                    showNotice(.textCopied, duration: tuning.value(of: TuningCatalog.mediaSavedChipDuration))
                }]
            case .systemTranslate:
                guard let plain = text.text else { return [] }
                return [UIAction(title: item.title, image: item.image) { [weak self] _ in self?.translation.present(plain) }]
            case .customEmojis:
                let emojis = text.emojis.compactMap { emojiElement(for: $0, subject: nil) }
                // 1つなら絵文字のサブメニューを直に置く。多いと1段目が絵文字で埋まるため、2つ以上はまとめる。
                guard emojis.count > 1 else { return emojis }
                return [UIMenu(title: item.title, image: item.image, children: emojis)]
            }
        }
        return children.isEmpty ? nil : UIMenu(children: children)
    }
}

/// プロフィールの表示名、自己紹介、補足情報の行に付ける、文章のメニューの長押し。
/// リンク、メンション、ハッシュタグの上は、手前に重ねた`LinkHitArea`が長押しを受け、その行き先のメニューを出す。
/// 押した文章のビューを、余白を付けて今の見た目のまま持ち上げる。
@MainActor
final class ProfileTextMenuInteraction: NSObject, UIContextMenuInteractionDelegate {
    private weak var view: UIView?
    private let menu: @MainActor () -> UIMenu?
    /// 持ち上げたときの下地の色。nilならUIKitの既定の下地にする。補足情報の行では、文字の色をカードの色に合わせているため、カードの色を返す。
    private let previewBackground: @MainActor () -> UIColor?
    private let lifecycle: MenuLifecycle
    /// メニューを出している間、閉じ終えるまで自分とビューを持っておく。
    /// 絵文字の画像が届くとヘッダーが補足情報の行を作り直し、持ち主がこの部品を手放す。`UIContextMenuInteraction`の`delegate`は弱参照なので、
    /// そのままでは閉じたことを受け取れず、一覧の更新が溜まったままになるため。
    private var shown: (interaction: ProfileTextMenuInteraction, view: UIView)?

    init(on view: UIView, menu: @escaping @MainActor () -> UIMenu?, previewBackground: @escaping @MainActor () -> UIColor? = { nil }, lifecycle: MenuLifecycle) {
        self.view = view
        self.menu = menu
        self.previewBackground = previewBackground
        self.lifecycle = lifecycle
        super.init()
        view.isUserInteractionEnabled = true
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menu() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        if let view { shown = (self, view) }
        lifecycle.willShow()
    }

    /// 閉じるアニメーションの間も一覧を動かさない。
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        lifecycle.willEnd()
        guard let animator else {
            didHide()
            return
        }
        animator.addCompletion { [self] in didHide() }
    }

    private func didHide() {
        shown = nil
        lifecycle.didHide()
    }

    /// 文字がビューの端に接して見えないよう、まわりに余白を付けて持ち上げる。
    private func preview() -> UITargetedPreview? {
        guard let view, view.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds.insetBy(dx: -10, dy: -8), cornerRadius: 12)
        if let background = previewBackground() {
            parameters.backgroundColor = background
        }
        return UITargetedPreview(view: view, parameters: parameters)
    }
}
