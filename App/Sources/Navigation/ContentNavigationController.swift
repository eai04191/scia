import UIKit

/// タブごとの画面を積むナビゲーション。ステータスバーの文字の色を、いちばん上の画面に決めさせる。
/// 標準のナビゲーションは、バーを出している間はバーの見た目から色を決め、画面に尋ねない。
/// プロフィールのように、ヘッダー画像をステータスバーの下まで伸ばす画面が、画像の明るさで色を変えられるようにするため。
final class ContentNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    /// Macで、ナビゲーションバーのボタンのない場所をクリックしたとき。
    /// iPhoneでは、UIKitがそこへのタップをステータスバーのタップと同じく扱い、タイムラインを最上部へ戻すが、MacのDesigned for iPadではしないため。
    var onEmptyBarClickOnMac: (() -> Void)?

    /// 画面の下端から、投稿欄のカプセルとキーボード、アプリ内のSafariのシートが覆っている高さ。
    /// 積んだどの画面でも末尾が裏に隠れないよう、タブバーなどでsafe areaに入っている分を超えて覆っている分を、積んだ画面のsafe areaに足す。
    /// ナビゲーション自身のsafe areaには足さない。足すとタブバーがナビゲーションに渡す余白を測り直し、safe areaの変化の知らせが止まらなくなるため。
    /// 下側のsafe areaを広げるだけなので、スクロールする画面の上端を基準にした読んでいる位置は動かない。ただし末尾までスクロールしていると、
    /// 下端を覆うものがなくなったときに末尾が下端に合わせて下がる。末尾は古い投稿を読み込む途中で留まる場所ではなく、そこで書き始めることはまれなため、補正しない。
    var coveredBottomHeight: CGFloat = 0 {
        didSet { applyCoveredBottom(to: viewControllers) }
    }

    override init(rootViewController: UIViewController) {
        super.init(navigationBarClass: ContentNavigationBar.self, toolbarClass: nil)
        viewControllers = [rootViewController]
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        applyCoveredBottom(to: [viewController])
        super.pushViewController(viewController, animated: animated)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        applyCoveredBottom(to: viewControllers)
        super.setViewControllers(viewControllers, animated: animated)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyCoveredBottom(to: viewControllers)
    }

    /// 画面を読み込む前は値だけを覚え、読み込んだあとのsafe areaの変化で反映する。
    private func applyCoveredBottom(to viewControllers: [UIViewController]) {
        guard isViewLoaded else { return }
        let extra = max(0, coveredBottomHeight - view.safeAreaInsets.bottom)
        for viewController in viewControllers where viewController.additionalSafeAreaInsets.bottom != extra {
            viewController.additionalSafeAreaInsets.bottom = extra
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let click = UITapGestureRecognizer(target: self, action: #selector(emptyBarClicked))
        click.delegate = self
        click.cancelsTouchesInView = false
        navigationBar.addGestureRecognizer(click)
    }

    @objc private func emptyBarClicked() {
        onEmptyBarClickOnMac?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view, let bar = navigationBar as? ContentNavigationBar else { return false }
        return bar.isEmptyArea(view)
    }
}

/// ナビゲーションバーのボタンのない場所のタップを、下の画面に通すかを決める画面。
@MainActor
protocol NavigationBarTapPassing: UIViewController {
    /// ナビゲーションバーの下に、タップを受ける表示（ヘッダー画像）を入れている。
    var passesEmptyNavigationBarTaps: Bool { get }
}

/// ボタンのない場所のタップを、いちばん上の画面が望めば下に通すナビゲーションバー。
/// 標準のバーは、背景を描かないときもバー全体でタップを受けるため、バーの下に入れたヘッダー画像を押せない。
private final class ContentNavigationBar: UINavigationBar {
    /// 触れたものを受けたビューが、ボタンのない場所か。
    /// ボタンは、バーの中身のビューのさらに内側にある。バーかその中身のビューそのものが受けたら、ボタンのない場所。
    func isEmptyArea(_ view: UIView) -> Bool {
        view === self || view.superview === self
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 中身の組み方が変わってこの判定が外れても、今までどおりバーが受けるだけで、ボタンが押せなくなることはない。
        guard let hit, isEmptyArea(hit),
              let top = (delegate as? UINavigationController)?.topViewController as? any NavigationBarTapPassing,
              top.passesEmptyNavigationBarTaps
        else { return hit }
        return nil
    }
}
