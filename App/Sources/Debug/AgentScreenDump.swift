#if DEBUG
import os
import SciaCore
import UIKit

/// 画面にある要素を、agentが読める文字にする。`scia-debug://dump`で書き出す。
/// スクリーンショットを読まずに、タップする座標や今の画面を知るため。VoiceOverが読む要素をたどるので、SwiftUIの画面の要素も出る。
@MainActor
enum AgentScreenDump {
    /// 画面が止まるのを待ってから書き出す。スクリーンショットを撮り比べて待つより速く、動きの途中を書き出さない。
    static func write(scene: UIWindowScene?) {
        Task { @MainActor in
            let started = ContinuousClock.now
            let moving = await waitUntilSettled(scene: scene)
            let elapsed = started.duration(to: .now).components
            let seconds = String(format: "%.1f", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            let status = moving.map { "画面: 止まっていない（\(settleTimeout.components.seconds)秒で諦めた。動いているもの: \($0)）" } ?? "画面: 止まった（\(seconds)秒）"
            save(status + "\n" + describe(scene: scene))
        }
    }

    private static let settleTimeout = Duration.seconds(5)
    /// 動きのない状態がこれだけ続いたら、止まったとみなす。新着の挿入のように、少し遅れて始まる動きを待つ。
    private static let quietPeriod = Duration.milliseconds(250)

    /// 止まったらnil、止まらないまま時間切れになったら、最後に動いていたものの説明を返す。
    private static func waitUntilSettled(scene: UIWindowScene?) async -> String? {
        guard let scene else { return nil }
        let deadline = ContinuousClock.now + settleTimeout
        var quietSince: ContinuousClock.Instant?
        var lastMoving: String?
        var previous: [ObjectIdentifier: ViewState] = [:]
        while ContinuousClock.now < deadline {
            let current = viewStates(in: scene)
            let changed = previous.isEmpty ? nil : changedView(from: previous, to: current)
            previous = current
            if let moving = changed ?? movingThing(in: scene) {
                lastMoving = moving
                quietSince = nil
            } else if let since = quietSince {
                if since.duration(to: .now) >= quietPeriod { return nil }
            } else {
                quietSince = .now
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lastMoving ?? "不明"
    }

    /// 画面の更新ごとに自前で動かす部品（CADisplayLinkで位置やcontentOffsetを書き換えるもの）は、
    /// アニメーションとしては見えないため、見えているビューの位置、大きさ、透明度、スクロール位置を前回と比べて捉える。
    private struct ViewState: Equatable {
        let name: String
        let frame: CGRect
        let alpha: CGFloat
        let contentOffset: CGPoint
    }

    private static func viewStates(in scene: UIWindowScene) -> [ObjectIdentifier: ViewState] {
        var states: [ObjectIdentifier: ViewState] = [:]
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha >= 0.01 else { return }
            states[ObjectIdentifier(view)] = ViewState(
                name: String(describing: type(of: view)),
                frame: view.convert(view.bounds, to: nil),
                alpha: view.alpha,
                contentOffset: (view as? UIScrollView)?.contentOffset ?? .zero
            )
            view.subviews.forEach(visit)
        }
        scene.windows.filter { !$0.isHidden }.forEach(visit)
        return states
    }

    private static func changedView(from previous: [ObjectIdentifier: ViewState], to current: [ObjectIdentifier: ViewState]) -> String? {
        for (id, state) in current where previous[id] != state {
            return "\(state.name)の位置や透明度の変化"
        }
        return previous.keys.contains { current[$0] == nil } ? "ビューの増減" : nil
    }

    private static func movingThing(in scene: UIWindowScene) -> String? {
        for window in scene.windows where !window.isHidden {
            if let moving = movingScrollView(in: window) ?? animatingLayer(in: window.layer) {
                return moving
            }
        }
        return nil
    }

    /// 終わりのあるアニメーションが残っているレイヤー。読み込み中の表示のようにずっと繰り返すものと、
    /// タブバーのガラスの表現（_UILiquidLensView）が位置を追いかけ続けるもののように、常駐する長いものは数えない。
    private static func animatingLayer(in layer: CALayer) -> String? {
        guard !layer.isHidden else { return nil }
        let keys = layer.animationKeys()?.filter { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            let length = animation.duration * Double(max(animation.repeatCount, 1))
            return animation.repeatCount != .infinity && animation.repeatDuration != .infinity && length <= 60
        } ?? []
        if !keys.isEmpty {
            let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            return "\(owner)のアニメーション \(keys.joined(separator: ","))"
        }
        for sublayer in layer.sublayers ?? [] {
            if let moving = animatingLayer(in: sublayer) { return moving }
        }
        return nil
    }

    /// 指で動かしている最中か、慣性で動いているスクロールビュー。
    private static func movingScrollView(in view: UIView) -> String? {
        guard !view.isHidden else { return nil }
        if let scrollView = view as? UIScrollView, scrollView.isDragging || scrollView.isDecelerating {
            return "\(type(of: scrollView))のスクロール"
        }
        for subview in view.subviews {
            if let moving = movingScrollView(in: subview) { return moving }
        }
        return nil
    }

    private static func save(_ text: String) {
        do {
            let directory = URL.documentsDirectory.appending(path: "AgentDump")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 読む側はファイルができたことで書き終わりを知るため、一時ファイルに書いてから置き換える。
            try Data(text.utf8).write(to: directory.appending(path: "screen.txt"), options: .atomic)
        } catch {
            SciaLog.logger(category: "debug").error("agent dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func describe(scene: UIWindowScene?) -> String {
        guard let scene else { return "シーンがない\n" }
        let screen = scene.screen.bounds
        var lines = ["画面: \(Int(screen.width))x\(Int(screen.height))pt 座標はタップと同じポイント。各行は 種類 \"名前\" 値 中心=(x,y) 枠=(x,y,幅,高さ)"]
        // 手前のウインドウから並べる。ビューアは別のウインドウに出すことがある。
        let windows = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }.sorted { $0.windowLevel > $1.windowLevel }
        for window in windows {
            var elements: [String] = []
            collect(window, screen: screen, covered: coveredViews(in: window), into: &elements)
            guard !elements.isEmpty else { continue }
            lines.append("")
            lines.append("ウインドウ \(type(of: window)) 画面の重なり: \(controllerChain(from: window.rootViewController).joined(separator: " > "))")
            lines.append(contentsOf: elements)
        }
        // スクロールの位置など、画面の要素からは分からない状態は、違和感レポートと同じ状態ダンプから出す。
        for dump in AppDependencies.stateDumps.dumpAll() {
            lines.append("")
            lines.append("状態 \(dump.name)")
            lines.append(contentsOf: dump.text.split(separator: "\n").map { "  \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 選んでいるタブ、ナビゲーションの一番上、重ねた画面の順に、画面の型の名前を並べる。
    private static func controllerChain(from root: UIViewController?) -> [String] {
        var chain: [String] = []
        var current = root
        while let controller = current {
            chain.append(name(of: controller))
            if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                chain.append("タブ\(tabs.selectedIndex)")
                appendNavigation(selected, to: &chain)
            } else {
                appendNavigation(controller, to: &chain)
            }
            current = controller.presentedViewController
        }
        return chain
    }

    private static func appendNavigation(_ controller: UIViewController, to chain: inout [String]) {
        guard let navigation = controller as? UINavigationController else { return }
        chain.append(contentsOf: navigation.viewControllers.map(name(of:)))
    }

    private static func name(of controller: UIViewController) -> String {
        let name = String(describing: type(of: controller))
        // UIHostingController<ComposeView>のような名前は、中の画面の名前だけにする。
        if let open = name.firstIndex(of: "<"), name.hasPrefix("UIHostingController") {
            return String(name[name.index(after: open)...].dropLast())
        }
        return name
    }

    /// 上に画面を重ねている画面のビュー。下に隠れていて触れないため、書き出さない。
    private static func coveredViews(in window: UIWindow) -> Set<ObjectIdentifier> {
        var covered: Set<ObjectIdentifier> = []
        var current = window.rootViewController
        while let controller = current, let presented = controller.presentedViewController, !presented.isBeingDismissed {
            if let view = controller.viewIfLoaded {
                covered.insert(ObjectIdentifier(view))
            }
            current = presented
        }
        return covered
    }

    private static func collect(_ object: NSObject, screen: CGRect, covered: Set<ObjectIdentifier>, into lines: inout [String]) {
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden || covered.contains(ObjectIdentifier(view)) {
            return
        }
        if object.isAccessibilityElement {
            if let line = describe(object, screen: screen) {
                lines.append(line)
            }
            return
        }
        for child in children(of: object) {
            collect(child, screen: screen, covered: covered, into: &lines)
        }
    }

    /// VoiceOverがたどる子。要素を明示していればそれを、なければ子のビューを返す。
    private static func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        guard let view = object as? UIView else { return [] }
        return view.subviews
    }

    private static func describe(_ element: NSObject, screen: CGRect) -> String? {
        // VoiceOverが動いていないと、ビューのaccessibilityFrameは空になる。ビューなら画面上の位置から求める。
        var frame = (element as? UIView).map { $0.convert($0.bounds, to: nil) } ?? element.accessibilityFrame
        // 枠を後から決める要素は、描き直した直後に枠が空のままのことがある。そのときは入れ物のビューの枠を使う。
        if frame.isNull || frame.isEmpty, let container = (element as? UIAccessibilityElement)?.accessibilityContainer as? UIView {
            frame = container.convert(container.bounds, to: nil)
        }
        // タップに使う中心は、見えている部分から求める。一部だけ見えている行の枠の中心は、画面の外やバーの下を指すため。
        let visible = visibleFrame(of: element, frame: frame, screen: screen)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        let label = element.accessibilityLabel ?? ""
        let value = element.accessibilityValue ?? ""
        guard !label.isEmpty || !value.isEmpty || element is UIControl else { return nil }
        var parts = ["  \(kind(of: element))", "\"\(oneLine(label))\""]
        if !value.isEmpty { parts.append("値=\"\(oneLine(value))\"") }
        if element.accessibilityTraits.contains(.selected) { parts.append("選択中") }
        if element.accessibilityTraits.contains(.notEnabled) { parts.append("無効") }
        parts.append("中心=(\(Int(visible.midX)),\(Int(visible.midY)))")
        parts.append("枠=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))")
        return parts.joined(separator: " ")
    }

    /// 画面と、外側のスクロールビューの見えている範囲で切り取った枠。スクロールビューは、上下のバーに隠れる余白（adjustedContentInset）も除く。
    private static func visibleFrame(of element: NSObject, frame: CGRect, screen: CGRect) -> CGRect {
        var visible = frame.intersection(screen)
        var ancestor = (element as? UIView)?.superview ?? ((element as? UIAccessibilityElement)?.accessibilityContainer as? UIView)
        while let view = ancestor, !visible.isNull {
            if let scrollView = view as? UIScrollView {
                let shown = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
                visible = visible.intersection(scrollView.convert(shown, to: nil))
            } else if view.clipsToBounds {
                visible = visible.intersection(view.convert(view.bounds, to: nil))
            }
            ancestor = view.superview
        }
        return visible
    }

    private static func kind(of element: NSObject) -> String {
        let traits = element.accessibilityTraits
        if traits.contains(.button) { return "ボタン" }
        if traits.contains(.link) { return "リンク" }
        if traits.contains(.header) { return "見出し" }
        if traits.contains(.image) { return "画像" }
        if traits.contains(.adjustable) { return "調整" }
        if traits.contains(.searchField) { return "検索欄" }
        if element is UITextView || element is UITextField { return "入力欄" }
        if traits.contains(.staticText) { return "文字" }
        return String(describing: type(of: element))
    }

    /// 投稿の本文などの改行を、1行に収めるため空白にする。長すぎる名前は切る。
    private static func oneLine(_ text: String) -> String {
        // カスタム絵文字は画像の置き換え文字（U+FFFC）と幅のない空白（U+FEFF）になっているため除く。
        let flattened = text.replacingOccurrences(of: "\n", with: " ").filter { $0 != "\u{FFFC}" && $0 != "\u{FEFF}" }
        return flattened.count > 120 ? String(flattened.prefix(120)) + "…" : flattened
    }
}
#endif
