import UIKit

/// ウィンドウの根に置く入れ物。アプリ内のSafariを伏せた高さまで下げている間、中の画面（タブ）を縮めて下の角を丸くし、シートとの間に黒い隙間を空ける。
final class InAppBrowserDockContainer: UIViewController {
    let content: UIViewController
    /// 下に空ける高さ。シートの高さと隙間を足したもの。空けていなければ0。
    private(set) var reservedHeight: CGFloat = 0

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
        content.view.clipsToBounds = true
        content.view.layer.cornerCurve = .continuous
        content.view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - reservedHeight))
    }

    /// `reservedHeight`が0なら元の大きさに戻す。動いている途中に呼ばれても、今の位置から向け直す。
    func setReservedHeight(_ height: CGFloat, cornerRadius: CGFloat, duration: TimeInterval) {
        guard height != reservedHeight else { return }
        reservedHeight = height
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        UIView.animateSmoothly(duration: duration) {
            self.content.view.layer.cornerRadius = height > 0 ? cornerRadius : 0
            self.view.layoutIfNeeded()
        }
    }
}
