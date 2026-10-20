import UIKit

/// タブごとの画面を積むナビゲーション。ステータスバーの文字の色を、いちばん上の画面に決めさせる。
/// 標準のナビゲーションは、バーを出している間はバーの見た目から色を決め、画面に尋ねない。
/// プロフィールのように、ヘッダー画像をステータスバーの下まで伸ばす画面が、画像の明るさで色を変えられるようにするため。
final class ContentNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        super.init(navigationBarClass: ContentNavigationBar.self, toolbarClass: nil)
        viewControllers = [rootViewController]
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }
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
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // ボタンは、バーの中身のビューのさらに内側にある。バーかその中身のビューそのものが受けたら、ボタンのない場所。
        // 中身の組み方が変わってこの判定が外れても、今までどおりバーが受けるだけで、ボタンが押せなくなることはない。
        guard let hit, hit === self || hit.superview === self,
              let top = (delegate as? UINavigationController)?.topViewController as? any NavigationBarTapPassing,
              top.passesEmptyNavigationBarTaps
        else { return hit }
        return nil
    }
}
