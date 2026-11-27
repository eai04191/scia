import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 投稿欄の開閉で、カプセルと書いているときの行のあいだを動かす複製。
@MainActor
@Suite(.failureState)
struct ComposeMorphFlightsTests {
    /// 行き先へ動かし始めたのと同じ回に行き先を測り直しても、複製は起点の形から動く。
    /// 書き終えたことが届いた直後に行が並べ直され、まだ一度も描いていない複製を止めると、
    /// 見えている形を読めずに行き先の値で止まり、閉じ始めに複製が行き先へ1コマで移っていた。
    @Test func retargetBeforeFirstDrawStartsFromSource() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let target = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        container.addSubview(source)
        container.addSubview(target)
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.chip
        func end(_ view: UIView) -> ComposeMorphFlights.End {
            .init(view: view, content: .thumbnail(Self.thumbnail(.undecorated(size: view.bounds.size)))) { view.alpha = $0 ? 0 : 1 }
        }

        flights.takeOff(from: [key: end(source)], stackingOrder: [key], stackShadowOpacity: 0)
        var generation = 0
        UIView.animate(withDuration: 1) {
            generation = flights.land(on: [key: end(target)], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }
        target.frame.origin.y = 320
        flights.retarget(on: [key: end(target)], generation: generation) { _, animations in
            UIView.animate(withDuration: 1, animations: animations)
        }

        let copies = container.subviews.flatMap(\.subviews).filter { $0 !== source && $0 !== target }
        let copy = try #require(copies.first)
        let move = try #require(copy.layer.animation(forKey: "position") as? CABasicAnimation)
        let from = try #require(move.fromValue as? CGPoint)
        // UIKitの動きは、行き先との差を足し合わせて動かす（`isAdditive`）。差から、動き始める位置を求める。
        let start = move.isAdditive ? CGPoint(x: copy.center.x + from.x, y: copy.center.y + from.y) : from
        #expect(start == CGPoint(x: source.frame.midX, y: source.frame.midY))
        #expect(copy.center == CGPoint(x: target.frame.midX, y: target.frame.midY))
    }

    /// カプセルから動き始める写真の複製は、起点の写真が受けていた写真同士の影を載せて動き始める。
    /// 載せないと、動き始めのコマで、手前の写真が奥の写真に落としていた影が1コマで消える。
    @Test func takeOffCarriesBetweenShadow() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 26, height: 26))
        container.addSubview(source)
        let shadow = UIView()
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())
        let end = ComposeMorphFlights.End(view: source, content: .thumbnail(Self.thumbnail(.undecorated(size: source.bounds.size), cornerRadius: 3, border: 2, betweenShadow: shadow))) { source.alpha = $0 ? 0 : 1 }

        flights.takeOff(from: [key: end], stackingOrder: [key], stackShadowOpacity: 0)

        let copy = try #require(shadow.superview)
        #expect(copy.bounds.size == source.bounds.size)
        #expect(shadow.frame == copy.bounds)
        // 複製の大きさに合わせて伸び縮みする。
        #expect(shadow.autoresizingMask == [.flexibleWidth, .flexibleHeight])
        // 載せた影は、動き始めに薄くし始める。
        #expect(shadow.alpha == 0)
    }
    /// 列のサムネイルへ向かう複製は、サムネイルに重ねている表示（バッジなど）を載せ、近づくにつれて不透明度を上げる。
    /// 載せないと、列に着いて本物に替わったコマで、バッジが1コマで付く。
    @Test func landingOnStripFadesInBadge() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let source = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        let target = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        container.addSubview(source)
        container.addSubview(target)
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())

        flights.takeOff(from: [key: .init(view: source, content: .thumbnail(Self.thumbnail(.undecorated(size: source.bounds.size)))) { source.alpha = $0 ? 0 : 1 }], stackingOrder: [key], stackShadowOpacity: 0)
        UIView.animate(withDuration: 1) {
            _ = flights.land(
                on: [key: .init(view: target, content: .thumbnail(Self.thumbnail(Self.badged(size: target.bounds.size)))) { target.alpha = $0 ? 0 : 1 }],
                delays: [:], stackShadowOpacity: 0, duration: 1
            ) { _, animations in animations() }
        }

        let badge = try #require(Self.badges(in: container).first { !$0.isHidden }, "複製にバッジを載せていません")
        #expect(badge.alpha == 1)
        let fade = try #require(badge.layer.animation(forKey: "opacity") as? CABasicAnimation, "バッジを濃くしていません")
        #expect((fade.fromValue as? Float) == 0)
    }

    /// 列のサムネイルからカプセルへ向かう複製は、バッジを載せて動き始め、カプセルに近づくにつれて薄くする。カプセルの写真はバッジを出さないため。
    @Test func takingOffFromStripFadesOutBadge() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let target = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        container.addSubview(source)
        container.addSubview(target)
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())

        flights.takeOff(from: [key: .init(view: source, content: .thumbnail(Self.thumbnail(Self.badged(size: source.bounds.size)))) { source.alpha = $0 ? 0 : 1 }], stackingOrder: [key], stackShadowOpacity: 0)
        let badge = try #require(Self.badges(in: container).first { !$0.isHidden }, "複製にバッジを載せていません")
        #expect(badge.alpha == 1)
        UIView.animate(withDuration: 1) {
            _ = flights.land(on: [key: .init(view: target, content: .thumbnail(Self.thumbnail(.undecorated(size: target.bounds.size)))) { target.alpha = $0 ? 0 : 1 }], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }

        #expect(badge.alpha == 0)
        let fade = try #require(badge.layer.animation(forKey: "opacity") as? CABasicAnimation, "バッジを薄くしていません")
        #expect((fade.fromValue as? Float) == 1)
    }

    /// カプセルの写真へ向かう複製は、写真の右下の失敗のアイコンを載せ、近づくにつれて不透明度を上げる。本物に替えたあとでフェードインさせると、
    /// 開閉の完了は動きが止まって見えてからしばらく後なので、写真が止まってからアイコンが遅れて出る。
    @Test func landingOnCapsuleFadesInFailureMarkOnCopy() throws {
        // 本物のスナップショットを撮るので、ウィンドウに載せる。
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let target = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        let mark = UIView(frame: CGRect(x: 18, y: 18, width: 14, height: 14))
        mark.backgroundColor = .systemRed
        target.addSubview(mark)
        container.addSubview(source)
        container.addSubview(target)
        // スナップショットは描いたことのあるビューからしか撮れない。
        CATransaction.flush()
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())

        flights.takeOff(from: [key: .init(view: source, content: .thumbnail(Self.thumbnail(.undecorated(size: source.bounds.size)))) { source.alpha = $0 ? 0 : 1 }], stackingOrder: [key], stackShadowOpacity: 0)
        var generation = 0
        UIView.animate(withDuration: 1) {
            generation = flights.land(
                on: [key: .init(view: target, content: .thumbnail(Self.thumbnail(.undecorated(size: target.bounds.size), status: .bottomTrailingCorner(mark)))) { target.alpha = $0 ? 0 : 1 }],
                delays: [:], stackShadowOpacity: 0, duration: 1
            ) { _, animations in animations() }
        }

        let copies = container.subviews.flatMap(\.subviews).filter { $0 !== mark && $0.bounds.size == mark.bounds.size }
        let copy = try #require(copies.first, "複製に失敗のアイコンを載せていません")
        #expect(copy.alpha == 1)
        let fade = try #require(copy.layer.animation(forKey: "opacity") as? CABasicAnimation, "失敗のアイコンを濃くしていません")
        #expect((fade.fromValue as? Float) == 0)
        // 複製が行き先の大きさになったとき、本物のアイコンと重なる。
        let holder = try #require(copy.superview)
        holder.bounds.size = target.bounds.size
        holder.layoutIfNeeded()
        #expect(copy.frame == mark.frame)

        flights.finish(generation: generation)
        #expect(mark.layer.animation(forKey: "opacity") == nil, "本物に替えてから、失敗のアイコンを浮かび上がらせています")
    }

    /// 描く前に行き先を測り直し、そのまま逆へ向かうとき、行き先の失敗のアイコンのスナップショットは、まだ見せていない不透明度に戻る。
    /// 測り直しで撮り直したスナップショットを戻さないと、見せ始める前のアイコンが濃いまま起点へ向かう。
    @Test func reversingBeforeFirstDrawKeepsTargetMarkHidden() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let source = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let target = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        let mark = UIView(frame: CGRect(x: 18, y: 18, width: 14, height: 14))
        mark.backgroundColor = .systemRed
        target.addSubview(mark)
        container.addSubview(source)
        container.addSubview(target)
        // スナップショットは描いたことのあるビューからしか撮れない。
        CATransaction.flush()
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())
        let strip = ComposeMorphFlights.End(view: source, content: .thumbnail(Self.thumbnail(.undecorated(size: source.bounds.size)))) { source.alpha = $0 ? 0 : 1 }
        func capsule() -> ComposeMorphFlights.End {
            .init(view: target, content: .thumbnail(Self.thumbnail(.undecorated(size: target.bounds.size), status: .bottomTrailingCorner(mark)))) { target.alpha = $0 ? 0 : 1 }
        }

        flights.takeOff(from: [key: strip], stackingOrder: [key], stackShadowOpacity: 0)
        var generation = 0
        UIView.animate(withDuration: 1) {
            generation = flights.land(on: [key: capsule()], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }
        target.frame.origin.y = 320
        flights.retarget(on: [key: capsule()], generation: generation) { _, animations in
            UIView.animate(withDuration: 1, animations: animations)
        }
        flights.takeOff(from: [key: capsule()], stackingOrder: [key], stackShadowOpacity: 0)

        let marks = container.subviews.flatMap(\.subviews).filter { $0 !== mark && $0.bounds.size == mark.bounds.size }
        #expect(marks.count == 1)
        #expect(marks.allSatisfy { $0.alpha == 0 }, "見せ始める前の失敗のアイコンを、濃いまま戻しています")
    }

    /// 動いている途中に向かい直すとき、同じ本物でも重ねた表示が変わっていれば、変わったあとの表示へ向かう。
    /// 動画の読み込み前に閉じ始め、読み込み終えてから開き直すと、列のサムネイルに再生アイコンが付いている。前の表示のままだと、着地のコマで再生アイコンが付く。
    @Test func reversingTowardChangedDecorationShowsIt() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let strip = UIView(frame: CGRect(x: 16, y: 10, width: 64, height: 64))
        let capsule = UIView(frame: CGRect(x: 16, y: 300, width: 26, height: 26))
        container.addSubview(strip)
        container.addSubview(capsule)
        let flights = ComposeMorphFlights(container: container)
        let key = ComposeMorphFlights.Key.attachment(UUID())
        func end(_ view: UIView, _ layout: MediaTileDecorationLayout) -> ComposeMorphFlights.End {
            .init(view: view, content: .thumbnail(Self.thumbnail(layout))) { view.alpha = $0 ? 0 : 1 }
        }

        flights.takeOff(from: [key: end(strip, .undecorated(size: strip.bounds.size))], stackingOrder: [key], stackShadowOpacity: 0)
        UIView.animate(withDuration: 1) {
            _ = flights.land(on: [key: end(capsule, .undecorated(size: capsule.bounds.size))], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }
        flights.takeOff(from: [key: end(capsule, .undecorated(size: capsule.bounds.size))], stackingOrder: [key], stackShadowOpacity: 0)
        UIView.animate(withDuration: 1) {
            _ = flights.land(on: [key: end(strip, Self.playing(size: strip.bounds.size))], delays: [:], stackShadowOpacity: 0, duration: 1) { _, animations in animations() }
        }

        #expect(Self.decorations(in: container).contains { $0.decoration.showsPlay && $0.view(for: .play).alpha == 1 }, "向かい直した先の再生アイコンを見せていません")
    }

    /// ラベルのアイコンの複製は、本物から渡された色で描く。決まった色で描くと、本物の色を変えたときに、両端でアイコンの色が1コマで替わる。
    @Test func symbolCopyUsesRealTint() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let source = UIImageView(image: UIImage(systemName: "clock"))
        source.frame = CGRect(x: 16, y: 10, width: 20, height: 20)
        source.tintColor = .systemRed
        container.addSubview(source)
        let flights = ComposeMorphFlights(container: container)

        flights.takeOff(from: [.schedule: .init(view: source, content: .symbol(source.image, tint: source.tintColor)) { source.alpha = $0 ? 0 : 1 }], stackingOrder: [.schedule], stackShadowOpacity: 0)

        let copies = container.subviews.flatMap(\.subviews).compactMap { $0 as? UIImageView }
        let copy = try #require(copies.first)
        #expect(copy.tintColor == .systemRed)
    }

    private static func thumbnail(
        _ layout: MediaTileDecorationLayout,
        cornerRadius: CGFloat = 0,
        border: CGFloat = 0,
        status: ComposeMorphFlights.StatusOverlay? = nil,
        betweenShadow: UIView? = nil
    ) -> ComposeMorphFlights.Thumbnail {
        ComposeMorphFlights.Thumbnail(image: nil, focus: nil, decoration: layout, cornerRadius: cornerRadius, border: border, status: status, betweenShadow: betweenShadow)
    }

    /// 動画の再生アイコンを出しているタイル。
    private static func playing(size: CGSize) -> MediaTileDecorationLayout {
        MediaTileDecorationLayout(
            decoration: MediaTileDecoration(showsPlay: true, badgeMarks: [], showsBadge: true, symbol: nil, hiddenCount: 0),
            sizing: MediaTileSymbolSizing(ratio: 0.4, range: 10...36),
            size: size
        )
    }

    private static func decorations(in view: UIView) -> [MediaTileDecorationView] {
        (view as? MediaTileDecorationView).map { [$0] } ?? view.subviews.flatMap(decorations(in:))
    }

    /// GIFのバッジを出しているタイル。
    private static func badged(size: CGSize) -> MediaTileDecorationLayout {
        MediaTileDecorationLayout(
            decoration: MediaTileDecoration(showsPlay: false, badgeMarks: [.gif], showsBadge: true, symbol: nil, hiddenCount: 0),
            sizing: MediaTileSymbolSizing(ratio: 0.4, range: 10...36),
            size: size
        )
    }

    private static func badges(in view: UIView) -> [MediaBadgeView] {
        (view as? MediaBadgeView).map { [$0] } ?? view.subviews.flatMap(badges(in:))
    }
}
