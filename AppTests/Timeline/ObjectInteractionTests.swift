import Testing
import UIKit
@testable import Scia

/// 対象のタップと長押しを付けた部品で、長押しのメニューを出すときに何を持ち上げるかを確かめる。決まりはdocs/menus.mdの「持ち上げ方」にある。
@MainActor
final class ObjectInteractionTests {
    private let window: UIWindow

    /// Swift Testingは、テストを終えたスイートの値をメインスレッドの外で手放す。持っているウィンドウやビューもそこで手放され、UIKitの解放がメインスレッドの外で走ると、
    /// 続くテストの描画と競って、解放中のウィンドウへのweak参照や解放済みのビューを触って落ちる。メインスレッドで手放させる。
    isolated deinit {}

    init() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    /// 押した位置を、メニューの構成の識別子に入れる（`ObjectInteraction`が構成を作るときと同じ）。
    private func previews(lift: ObjectLift, on view: UIView) throws -> (highlight: UITargetedPreview?, dismissal: UITargetedPreview?) {
        let objectInteraction = ObjectInteraction(on: view, tapsSelf: true, lift: lift)
        let interaction = try #require(view.interactions.lazy.compactMap { $0 as? UIContextMenuInteraction }.first)
        let configuration = UIContextMenuConfiguration(identifier: NSValue(cgPoint: CGPoint(x: 10, y: 12)), previewProvider: nil, actionProvider: nil)
        let identifier = NSString(string: "item")
        let highlight = objectInteraction.contextMenuInteraction(interaction, configuration: configuration, highlightPreviewForItemWithIdentifier: identifier)
        let dismissal = objectInteraction.contextMenuInteraction(interaction, configuration: configuration, dismissalPreviewForItemWithIdentifier: identifier)
        return (highlight, dismissal)
    }

    /// アイコンは、押したビューを今の角丸の形のまま持ち上げ、同じ形で戻す。
    @Test func shapeLiftsTheViewWithItsCorners() throws {
        defer { window.isHidden = true }
        let avatar = UIView(frame: CGRect(x: 20, y: 100, width: 48, height: 48))
        avatar.layer.cornerRadius = 9.6
        window.rootViewController?.view.addSubview(avatar)

        let previews = try previews(lift: .shape, on: avatar)

        for preview in [previews.highlight, previews.dismissal] {
            let preview = try #require(preview)
            #expect(preview.view === avatar)
            #expect(preview.parameters.visiblePath?.cgPath == UIBezierPath(roundedRect: avatar.bounds, cornerRadius: 9.6).cgPath)
        }
    }

    /// 文字の行は、一覧の行と同じく持ち上げず、押した位置に置いた見えない目印からメニューだけを出す。
    @Test func noneShowsMenuAtTouchWithoutLifting() throws {
        defer { window.isHidden = true }
        let header = UILabel(frame: CGRect(x: 60, y: 100, width: 300, height: 20))
        window.rootViewController?.view.addSubview(header)

        let previews = try previews(lift: .none, on: header)

        for preview in [previews.highlight, previews.dismissal] {
            let preview = try #require(preview)
            #expect(preview.view !== header)
            #expect(preview.target.container === header)
            #expect(preview.target.center == CGPoint(x: 10, y: 12))
        }
    }
}
