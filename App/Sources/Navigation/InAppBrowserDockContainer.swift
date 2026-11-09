import UIKit

/// ウィンドウの根に置く入れ物。アプリ内のSafariを伏せた高さまで下げている間、中の画面（タブ）を縮めて下の角を丸くし、シートとの間に黒い隙間を空ける。
final class InAppBrowserDockContainer: UIViewController {
    let content: UIViewController
    /// 中の画面を見せる範囲。下の角を丸くし、はみ出した分を切る。
    private let visibleArea = UIView()
    /// 下に空ける高さ。シートの高さと隙間を足したもの。空けていなければ0。
    private(set) var reservedHeight: CGFloat = 0
    /// 中の画面を、見せる範囲より下へはみ出させる長さ。
    /// `UITabBarController`は、下の安全領域が0でも、タブバーを全画面のときと同じだけ下端から浮かせて置き、この空きを変えるAPIがない。中の画面を長くすると、タブバーとその上のカプセルが一緒に下がる。
    private var contentOverhang: CGFloat = 0

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { content.supportedInterfaceOrientations }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(content)
        visibleArea.clipsToBounds = true
        visibleArea.layer.cornerCurve = .continuous
        visibleArea.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        view.addSubview(visibleArea)
        visibleArea.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let visibleHeight = max(0, view.bounds.height - reservedHeight)
        visibleArea.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: visibleHeight)
        content.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: visibleHeight + contentOverhang)
    }

    /// `reservedHeight`が0なら元の大きさに戻す。動いている途中に呼ばれても、今の位置から向け直す。
    func setReservedHeight(_ height: CGFloat, contentOverhang: CGFloat, cornerRadius: CGFloat, duration: TimeInterval) {
        let overhang = height > 0 ? contentOverhang : 0
        guard height != reservedHeight || overhang != self.contentOverhang else { return }
        reservedHeight = height
        self.contentOverhang = overhang
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        UIView.animateSmoothly(duration: duration) {
            self.visibleArea.layer.cornerRadius = height > 0 ? cornerRadius : 0
            self.view.layoutIfNeeded()
        }
    }
}
