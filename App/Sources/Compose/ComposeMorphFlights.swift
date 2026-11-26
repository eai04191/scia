import SciaCore
import UIKit

/// 投稿欄の開閉で、カプセルのラベルのアイコンと写真を、書いているときのラベルとサムネイルの列の同じものの位置へ動かす。
///
/// カプセルの行と書いているときの行は、スタックビューの中で入れ替えるので、行の中身を行の外へは動かせない。
/// 両方の端の本物を隠し、バーの上に重ねた複製を、行を入れ替えるのと同じアニメーションの中で動かす。
/// 複製はバーの中に置くので、キーボードに乗ってバーごと動いても、バーの中の位置だけを動かせばよい。
/// カプセルの写真は白いフチが付いて回っているので、複製も大きさ、回転、フチの幅、radiusを一緒に移す。
/// カプセルの写真のスタックは、輪郭を合わせた形で影を1つだけ落とす。動いている複製はスタックの形が崩れていくので、写真の複製をまとめて1つの入れ物に入れ、
/// 入れ物の影として、動いている途中の形のまま描く。写真同士の影は、動いている間は描かない。カプセルから動き始めるときは、
/// 写真同士の影のスナップショットを複製に載せて薄くし、着くときは、着いてから本物の影をフェードインさせて、どちらの端でも1コマで替わらないようにする。
@MainActor
final class ComposeMorphFlights {
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    enum Key: Hashable {
        case chip
        /// 予約の時計。
        case schedule
        case attachment(DraftAttachment.ID)
    }

    /// 動かす起点か行き先の本物。
    struct End {
        let view: UIView
        let content: Content
        /// 動かしている間、本物を見えなくする。重ねた表示も一緒に隠す。
        let conceal: (Bool) -> Void
    }

    /// 複製に描く中身。どの値にも既定値を付けず、両端の本物の見え方を渡し忘れると、コンパイルが通らないようにする。
    enum Content {
        /// ラベルのアイコン。複製は`tint`の色で描くので、本物の色を渡す。
        case symbol(UIImage?, tint: UIColor)
        case thumbnail(Thumbnail)
    }

    struct Thumbnail {
        let image: UIImage?
        let focus: MediaFocus?
        /// 上に重ねている表示（`MediaTileView.decorationLayout`）。本物と同じ部品で複製にも描く。
        let decoration: MediaTileDecorationLayout
        let cornerRadius: CGFloat
        /// 白いフチの幅。カプセルの写真だけに付く。
        let border: CGFloat
        /// 送信の状態の表示。両端の表示のスナップショットを複製に載せ、起点のものを薄くしながら行き先のものを濃くする。出していなければnil。
        let status: StatusOverlay?
        /// 上に重ねた写真が落としている影のスナップショット。起点にあれば複製に載せ、動き始めに薄くする。
        let betweenShadow: UIView?
    }

    /// 写真に重ねた送信の状態の表示と、複製の大きさが変わるときの置き方。
    enum StatusOverlay {
        /// 写真の上に収まる表示（列のサムネイルの暗い下地や失敗のアイコンなど）。中の画像の中央に元の大きさのまま置き、画像の枠で切る。
        case covering(UIView)
        /// 写真の右下の角に掛かる表示（カプセルの写真の失敗のアイコン）。角からの位置を保ち、写真の外にはみ出して描く。
        case bottomTrailingCorner(UIView)

        var view: UIView {
            switch self {
            case .covering(let view), .bottomTrailingCorner(let view): view
            }
        }

        /// 見えているものがあるか。何も出していなければ、スナップショットを載せない。
        @MainActor
        var showsSomething: Bool {
            switch self {
            case .covering(let view): view.subviews.contains { !$0.isHidden && $0.alpha > 0 }
            case .bottomTrailingCorner(let view): !view.isHidden && view.alpha > 0
            }
        }
    }

    private struct Flight {
        let copy: FlightCopy
        /// 隠した本物。動き終えたら、まとめて見せ直す。
        var ends: [End]
        /// 向かっている行き先の形。行が遅れて並べ直されたかを、これと比べて決める。
        var destination: FlightCopy.Geometry?
        /// 動き始める時刻。遅らせて動かす複製は、向かい直すときも、この時刻までは動かし始めない。
        var startTime: CFTimeInterval = 0
    }

    private let container: UIView
    /// 写真の複製をまとめる入れ物。中の複製を合わせた形で、カプセルの写真のスタックと同じ影を落とす。
    /// 動いている間は画面の外で再描画することになるので、動いていないときは影を消す。
    private lazy var shadowGroup: UIView = {
        let group = UIView(frame: container.bounds)
        group.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        group.isUserInteractionEnabled = false
        PhotoStackShadow.castStack(on: group.layer, opacity: 0)
        container.addSubview(group)
        return group
    }()
    private var flights: [Key: Flight] = [:]
    private var generation = 0
    private static let shadowAnimationKey = "stackShadowOpacity"

    init(container: UIView) {
        self.container = container
    }

    /// 起点の本物を隠し、同じ位置に複製を置く。動かしている途中の複製があれば、そのとき見えている位置から向かい直す。
    /// 行を入れ替える前に呼ぶ。複製は`order`の順に、後ろのものほど手前に重ねる。
    /// `stackShadowOpacity`は、起点で写真のスタックが落としている影の不透明度。動いている途中なら、見えている不透明度から向かい直す。
    func takeOff(from sources: [Key: End], stackingOrder order: [Key], stackShadowOpacity: Float) {
        let groupLayer = shadowGroup.layer
        if flights.isEmpty {
            groupLayer.removeAnimation(forKey: Self.shadowAnimationKey)
            groupLayer.shadowOpacity = stackShadowOpacity
        } else {
            let presented = groupLayer.presentation()?.shadowOpacity ?? groupLayer.shadowOpacity
            groupLayer.removeAnimation(forKey: Self.shadowAnimationKey)
            groupLayer.shadowOpacity = presented
        }
        for (key, var flight) in flights {
            flight.copy.freezeAtPresentation()
            if let source = sources[key] {
                conceal(source)
                flight.ends.append(source)
            }
            flights[key] = flight
        }
        for (key, source) in sources where flights[key] == nil {
            let copy = FlightCopy(content: source.content)
            // 写真の複製だけを影の入れ物に入れる。ラベルのアイコンは影を落とさない。
            if case .thumbnail = source.content {
                shadowGroup.addSubview(copy)
            } else {
                container.addSubview(copy)
            }
            copy.apply(geometry(of: source))
            if case .thumbnail(let thumbnail) = source.content {
                copy.attachStatus(thumbnail.status, of: source.view, shown: true)
                copy.attachTileDecoration(thumbnail.decoration, of: source.view, shown: true)
                if let betweenShadow = thumbnail.betweenShadow {
                    copy.attachBetweenShadow(betweenShadow)
                    UIView.animateSpring(duration: Self.decorationRevealDuration, in: copy) {
                        copy.betweenShadowAlpha = 0
                    }
                }
            }
            conceal(source)
            flights[key] = Flight(copy: copy, ends: [source])
        }
        container.bringSubviewToFront(shadowGroup)
        for key in order {
            if let copy = flights[key]?.copy {
                copy.superview?.bringSubviewToFront(copy)
            }
        }
        for key in order {
            if let overhang = flights[key]?.copy.overhang {
                container.bringSubviewToFront(overhang)
            }
        }
    }

    /// 複製を行き先の本物の位置へ動かし、行き先の本物を隠す。行き先のない複製は、薄くして消す。
    /// 行を入れ替えて並べ直したあと、同じアニメーションの中で呼ぶ。返した値を`finish`に渡す。
    /// `delays`にある複製は、その時間だけ遅らせて、`delayedAnimation`が返すアニメーションで動かす。遅らせた複製も、ほかと同じ時刻に着かせる。
    /// 写真のスタックの影は、`duration`の間に`stackShadowOpacity`（カプセルに着くならスタックの影の不透明度、列に着くなら0）へ向かわせる。
    func land(on targets: [Key: End], delays: [Key: TimeInterval], stackShadowOpacity: Float, duration: TimeInterval, delayedAnimation: (TimeInterval, @escaping () -> Void) -> Void) -> Int {
        generation += 1
        // 影の不透明度はUIKitのアニメーションで動かないので、Core Animationで、複製と同じ`.smooth`のスプリングで動かす。
        let groupLayer = shadowGroup.layer
        let animation = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        animation.keyPath = "shadowOpacity"
        animation.fromValue = groupLayer.shadowOpacity
        animation.toValue = stackShadowOpacity
        animation.duration = animation.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groupLayer.shadowOpacity = stackShadowOpacity
        CATransaction.commit()
        groupLayer.add(animation, forKey: Self.shadowAnimationKey)
        for (key, var flight) in flights {
            guard let target = targets[key] else {
                flight.copy.alpha = 0
                continue
            }
            // 行き先の重ねた表示も、この中で作る。アニメーションの中で作ると、作ったばかりのビューの`tintColor`の設定まで動き、三角が既定の色から白へ変わっていく。
            UIView.performWithoutAnimation {
                conceal(target)
                if case .thumbnail(let thumbnail) = target.content {
                    // 行き先のほうが大きな画像を描いていれば差し替え、カプセルの小さな画像を広げてぼやけさせない。
                    if let image = thumbnail.image {
                        flight.copy.replaceThumbnailIfLarger(image, focus: thumbnail.focus)
                    }
                    flight.copy.attachStatus(thumbnail.status, of: target.view, shown: false)
                    flight.copy.attachTileDecoration(thumbnail.decoration, of: target.view, shown: false)
                }
                flight.copy.markTileDecorationBeforeMove()
            }
            let targetView = target.view
            let destination = geometry(of: target)
            let delay = delays[key] ?? 0
            flight.ends.append(target)
            flight.destination = destination
            flight.startTime = mediaTime() + delay
            flights[key] = flight
            let copy = flight.copy
            let move = {
                copy.alpha = 1
                copy.apply(destination)
                copy.showStatus(of: targetView)
                copy.showTileDecoration(of: targetView)
            }
            if delay > 0 {
                delayedAnimation(delay, move)
            } else {
                move()
            }
        }
        return generation
    }

    /// `land`で測った行き先から本物が動いていたら、見えている位置から新しい行き先へ向かい直す。
    /// バーを指で引いてキーボードを閉じたときは、UIKitがキーボードを閉じ終える処理の中から書き終えたことが届き、その場で並べ直しても行が前の形のまま残る。
    /// 行は次の実行ループで並べ直されるので、高さ0のカプセルの行の位置に着いたまま、動き終わりに本物の位置へ飛んでいた。`land`の次の実行ループで呼ぶ。
    /// `animations`には、渡した遅れの時間だけ待ってから、渡した変更を残りの時間で動かすアニメーションを返す。遅らせて動かしている複製は、まだ動き始めていなければ、残りの遅れを守る。
    func retarget(on targets: [Key: End], generation: Int, animations: (TimeInterval, @escaping () -> Void) -> Void) {
        guard generation == self.generation else { return }
        let now = mediaTime()
        var moved: [(FlightCopy, FlightCopy.Geometry, TimeInterval, UIView)] = []
        for (key, var flight) in flights {
            guard let target = targets[key], let previous = flight.destination else { continue }
            let destination = geometry(of: target)
            guard destination != previous else { continue }
            if !flight.ends.contains(where: { $0.view === target.view }) {
                conceal(target)
                flight.ends.append(target)
            }
            flight.destination = destination
            flights[key] = flight
            flight.copy.freezeAtPresentation()
            if case .thumbnail(let thumbnail) = target.content {
                UIView.performWithoutAnimation {
                    flight.copy.attachStatus(thumbnail.status, of: target.view, shown: false)
                    flight.copy.attachTileDecoration(thumbnail.decoration, of: target.view, shown: false)
                }
            }
            moved.append((flight.copy, destination, max(flight.startTime - now, 0), target.view))
        }
        for (copy, destination, delay, targetView) in moved {
            animations(delay) {
                copy.apply(destination)
                copy.showStatus(of: targetView)
                copy.showTileDecoration(of: targetView)
            }
        }
    }

    /// 動き終えたら、複製を外して本物を見せ直す。あとから別の動きが始まっていれば、その動きに任せてfalseを返す。
    @discardableResult
    func finish(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        shadowGroup.layer.removeAnimation(forKey: Self.shadowAnimationKey)
        shadowGroup.layer.shadowOpacity = 0
        for flight in flights.values {
            flight.copy.removeFromSuperview()
            for end in flight.ends {
                end.conceal(false)
            }
        }
        flights = [:]
        return true
    }

    /// 動き始めに写真同士の影を薄くする時間。カプセルに着いてから写真同士の影をフェードインさせる時間と揃える。
    private static let decorationRevealDuration: TimeInterval = 0.15

    private func conceal(_ end: End) {
        UIView.performWithoutAnimation { end.conceal(true) }
    }

    /// 本物の、複製を置く入れ物の中での中心、大きさ、回転。回すのはカプセルの奥の写真だけで、その親は回っていない。
    private func geometry(of end: End) -> FlightCopy.Geometry {
        let view = end.view
        let (cornerRadius, border): (CGFloat, CGFloat) = switch end.content {
        case .symbol: (0, 0)
        case .thumbnail(let thumbnail): (thumbnail.cornerRadius, thumbnail.border)
        }
        return FlightCopy.Geometry(
            center: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: container),
            size: view.bounds.size,
            rotation: atan2(view.transform.b, view.transform.a),
            cornerRadius: cornerRadius,
            border: border
        )
    }
}

/// 開閉で動かす複製。カプセルの写真の白いフチは、中の画像を縮めて下地の白を見せて描く。
@MainActor
private final class FlightCopy: UIView {
    struct Geometry: Equatable {
        let center: CGPoint
        let size: CGSize
        let rotation: CGFloat
        let cornerRadius: CGFloat
        let border: CGFloat
    }

    private let inner: UIView
    private var border: CGFloat = 0
    /// 両端の写真に重ねている送信の状態の表示のスナップショット。本物ごとに持つ。
    private var statuses: [ObjectIdentifier: UIView] = [:]
    /// 写真の上に収まる状態の表示のスナップショットを入れる、中の画像と同じ大きさの入れ物。タイルの上の表示より手前に置く。
    private var coveringStatuses: UIView?
    /// 写真の外にはみ出す表示のスナップショットを入れる、複製と同じ位置、大きさ、回転で動かす入れ物。写真の複製を入れる影の入れ物の外に置く。
    /// 影の入れ物は中身の形で影を落とすので、中に置くと、本物では影を落とさない失敗のアイコンまで影を落とすため。
    private(set) var overhang: UIView?

    override var alpha: CGFloat {
        didSet { overhang?.alpha = alpha }
    }

    override func removeFromSuperview() {
        overhang?.removeFromSuperview()
        super.removeFromSuperview()
    }

    private func followWithOverhang() {
        guard let overhang else { return }
        overhang.bounds = bounds
        overhang.center = center
        overhang.transform = transform
    }

    /// 起点の写真に、上の写真が落としていた影のスナップショット。写真と同じ大きさなので、複製の大きさに合わせて伸び縮みさせる。
    private var betweenShadow: UIView?

    var betweenShadowAlpha: CGFloat {
        get { betweenShadow?.alpha ?? 0 }
        set { betweenShadow?.alpha = newValue }
    }

    func attachBetweenShadow(_ snapshot: UIView) {
        betweenShadow?.removeFromSuperview()
        betweenShadow = snapshot
        snapshot.isUserInteractionEnabled = false
        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(snapshot)
    }

    /// 両端のタイルの上の表示。本物と同じ部品で、それぞれのタイルの大きさで並べ、伸び縮みしても中の画像の角からの位置を保つ。本物ごとに持つ。
    private var tileDecorations: [ObjectIdentifier: (view: MediaTileDecorationView, layout: MediaTileDecorationLayout)] = [:]
    /// 再生アイコンを見せている表示。列とカプセルで再生アイコンの大きさが違い、2つを重ねて入れ替えると途中で丸が二重に見えるため、
    /// 1つだけを見せ、起点の大きさから行き先の大きさへ変えながら動かす。小さく作った丸と三角を広げるとぼけるので、大きいほうを縮めて動かす。
    private var playOwner: MediaTileDecorationView?
    /// 行き先へ向かい始める前の、重ねた表示の部品の`transform`と不透明度。まだ一度も描いていない複製を止めるとき、見えている形として使う。
    private var tileDecorationBeforeMove: [(view: UIView, transform: CGAffineTransform, alpha: CGFloat)] = []

    /// `view`の上の表示を載せる。`shown`がfalseなら、どの部品も見せずに載せ、`showTileDecoration`で濃くする。
    /// 再生アイコンの丸と三角より手前に、送信中の暗い下地などの重ねた表示（`attachDecoration`）を置く。列のサムネイルと同じ重なり順にするため。
    /// 同じ本物の表示を載せていても、表示が変わっていれば（動画を読み込み終えて再生アイコンが付いたなど）作り直し、部品の今の不透明度を引き継ぐ。
    func attachTileDecoration(_ layout: MediaTileDecorationLayout, of view: UIView, shown: Bool) {
        let id = ObjectIdentifier(view)
        let existing = tileDecorations[id]
        guard existing?.layout != layout else { return }
        let added = MediaTileDecorationView(frozen: layout)
        added.frame = inner.bounds
        added.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let existing {
            inner.insertSubview(added, aboveSubview: existing.view)
        } else if let coveringStatuses {
            inner.insertSubview(added, belowSubview: coveringStatuses)
        } else {
            inner.addSubview(added)
        }
        tileDecorations[id] = (added, layout)
        for part in MediaTileDecorationView.Part.allCases {
            added.view(for: part).alpha = existing.map { $0.view.view(for: part).alpha } ?? (shown ? 1 : 0)
        }
        if let existing {
            existing.view.removeFromSuperview()
            if existing.view === playOwner {
                // 見せていた再生アイコンを、作り直した表示へ、見えている大きさと不透明度のまま移す。作り直した表示になければ、ほかの表示から選び直す。
                let shownSize = shownPlaySize(of: existing.view)
                let alpha = existing.view.view(for: .play).alpha
                playOwner = nil
                if layout.decoration.showsPlay {
                    playOwner = added
                    applyPlay(shownSize)
                    added.view(for: .play).alpha = alpha
                } else {
                    tileDecorations.values.forEach { adoptPlay(of: $0.view) }
                }
                return
            }
            added.view(for: .play).alpha = 0
        }
        adoptPlay(of: added)
    }

    /// `added`の再生アイコンを、見せる1つにするか決める。まだ見せていなければ選び、見せているものより大きければ、見えている大きさと不透明度のまま替える。
    private func adoptPlay(of added: MediaTileDecorationView) {
        guard added.decoration.showsPlay else { return }
        guard let owner = playOwner else {
            playOwner = added
            return
        }
        guard owner !== added, Self.playSize(of: added).diameter > Self.playSize(of: owner).diameter else { return }
        let shownSize = shownPlaySize(of: owner)
        let alpha = owner.view(for: .play).alpha
        owner.view(for: .play).alpha = 0
        playOwner = added
        applyPlay(shownSize)
        added.view(for: .play).alpha = alpha
    }

    func markTileDecorationBeforeMove() {
        tileDecorationBeforeMove = tileDecorationParts.map { ($0, $0.transform, $0.alpha) }
    }

    /// アニメーションの中で呼ぶ。`view`の上の表示を見せ、ほかの本物の表示を薄くする。部品を足したら、ここで動かし方を決める。
    func showTileDecoration(of view: UIView) {
        let target = tileDecorations[ObjectIdentifier(view)]?.view
        for decoration in tileDecorations.values.map(\.view) {
            for part in MediaTileDecorationView.Part.allCases {
                switch part {
                case .play:
                    // 見せている1つだけを、行き先の大きさへ変える。行き先に再生アイコンがなければ薄くする。
                    guard decoration === playOwner else { continue }
                    if let target, target.decoration.showsPlay {
                        applyPlay(Self.playSize(of: target))
                        decoration.view(for: .play).alpha = 1
                    } else {
                        decoration.view(for: .play).alpha = 0
                    }
                case .symbol, .more, .badge:
                    // 起点のものを薄くし、行き先のものを濃くする。
                    decoration.view(for: part).alpha = decoration === target ? 1 : 0
                }
            }
        }
    }

    /// 重ねた表示の部品と、再生アイコンの三角と、送信の状態の表示のスナップショット。止めるときに、見えている形を読み戻す。
    private var tileDecorationParts: [UIView] {
        tileDecorations.values.map(\.view).flatMap { decoration in MediaTileDecorationView.Part.allCases.map(decoration.view(for:)) + [decoration.playGlyph] }
            + statuses.values
    }

    /// 再生アイコンの丸の直径と三角の幅。タイルは三角の大きさを丸の大きさから丸めて決めるので、丸と三角を別の倍率で縮める。
    private struct PlaySize {
        let diameter: CGFloat
        let glyph: CGFloat
    }

    private static func playSize(of decoration: MediaTileDecorationView) -> PlaySize {
        PlaySize(diameter: decoration.view(for: .play).bounds.width, glyph: decoration.playGlyph.intrinsicContentSize.width)
    }

    private func shownPlaySize(of decoration: MediaTileDecorationView) -> PlaySize {
        let size = Self.playSize(of: decoration)
        let scale = decoration.view(for: .play).transform.a
        return PlaySize(diameter: size.diameter * scale, glyph: size.glyph * scale * decoration.playGlyph.transform.a)
    }

    /// 見せている再生アイコンの丸と三角を、それぞれ`size`の大きさに見えるように縮める。
    private func applyPlay(_ size: PlaySize) {
        guard let owner = playOwner else { return }
        let native = Self.playSize(of: owner)
        guard native.diameter > 0, native.glyph > 0 else { return }
        let scale = size.diameter / native.diameter
        owner.view(for: .play).transform = CGAffineTransform(scaleX: scale, y: scale)
        let glyphScale = size.glyph / native.glyph / scale
        owner.playGlyph.transform = CGAffineTransform(scaleX: glyphScale, y: glyphScale)
    }

    /// `view`（両端の本物）に重ねた送信の状態の表示のスナップショットを載せる。`shown`がfalseなら見せずに載せ、`showStatus`で濃くする。
    /// 同じ本物のスナップショットを載せていれば、今の表示で撮り直して今の不透明度を引き継ぐ。撮れなければ前のスナップショットを残す。表示を出していなければ、載せていたスナップショットを外す。
    func attachStatus(_ status: ComposeMorphFlights.StatusOverlay?, of view: UIView, shown: Bool) {
        let id = ObjectIdentifier(view)
        let existing = statuses[id]
        guard let status, status.showsSomething else {
            existing?.removeFromSuperview()
            statuses[id] = nil
            return
        }
        guard let snapshot = status.view.snapshotView(afterScreenUpdates: false) else { return }
        existing?.removeFromSuperview()
        snapshot.isUserInteractionEnabled = false
        snapshot.alpha = existing?.alpha ?? (shown ? 1 : 0)
        // 動かす前の不透明度の記録も、撮り直したスナップショットへ移す。止めるときに、外したスナップショットではなく今のスナップショットを戻すため。
        tileDecorationBeforeMove = tileDecorationBeforeMove.map { part in
            part.view === existing ? (view: snapshot, transform: part.transform, alpha: part.alpha) : part
        }
        switch status {
        case .covering:
            let covering = coveringStatuses ?? {
                let covering = UIView(frame: inner.bounds)
                covering.isUserInteractionEnabled = false
                covering.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                inner.addSubview(covering)
                coveringStatuses = covering
                return covering
            }()
            snapshot.center = CGPoint(x: covering.bounds.midX, y: covering.bounds.midY)
            snapshot.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            covering.addSubview(snapshot)
        case .bottomTrailingCorner(let mark):
            guard let overhang = overhang ?? makeOverhang() else { return }
            // 複製が本物と同じ大きさになったとき本物と重なるよう、本物の右下の角からの位置で置く。行き先のスナップショットは、起点の大きさの複製に載せるため。
            let frame = mark.convert(mark.bounds, to: view)
            snapshot.frame = frame.offsetBy(dx: overhang.bounds.width - view.bounds.width, dy: overhang.bounds.height - view.bounds.height)
            snapshot.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            overhang.addSubview(snapshot)
        }
        statuses[id] = snapshot
    }

    private func makeOverhang() -> UIView? {
        guard let group = superview, let container = group.superview else { return nil }
        let overhang = UIView()
        overhang.isUserInteractionEnabled = false
        container.insertSubview(overhang, aboveSubview: group)
        self.overhang = overhang
        followWithOverhang()
        overhang.alpha = alpha
        return overhang
    }

    /// アニメーションの中で呼ぶ。`view`の送信の状態の表示を濃くし、ほかの本物の表示を薄くする。
    func showStatus(of view: UIView) {
        for (id, status) in statuses {
            status.alpha = id == ObjectIdentifier(view) ? 1 : 0
        }
    }

    init(content: ComposeMorphFlights.Content) {
        switch content {
        case .symbol(let image, let tint):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.tintColor = tint
            inner = imageView
        case .thumbnail(let thumbnail):
            let imageView = FocusCroppedImageView()
            imageView.image = thumbnail.image
            imageView.focus = thumbnail.focus
            imageView.backgroundColor = .secondarySystemFill
            inner = imageView
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        inner.clipsToBounds = true
        inner.layer.cornerCurve = .continuous
        // カプセルの写真の回転へ向かうので、縁がギザギザにならないようにする。
        layer.allowsEdgeAntialiasing = true
        inner.layer.allowsEdgeAntialiasing = true
        layer.cornerCurve = .continuous
        if case .thumbnail = content {
            backgroundColor = PhotoPaper.color
        }
        addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 最後に`apply`した形と、その前の形。まだ一度も描いていない複製を止めるとき、見えている形として前の形を使う。
    private var appliedGeometry: Geometry?
    private var previousGeometry: Geometry?

    /// アニメーションの中で呼ぶと、外枠、中の画像、radiusを一緒に動かす。
    func apply(_ geometry: Geometry) {
        previousGeometry = appliedGeometry ?? geometry
        appliedGeometry = geometry
        border = geometry.border
        bounds = CGRect(origin: .zero, size: geometry.size)
        center = geometry.center
        transform = CGAffineTransform(rotationAngle: geometry.rotation)
        layer.cornerRadius = geometry.cornerRadius
        inner.layer.cornerRadius = max(geometry.cornerRadius - geometry.border / 2, 0)
        followWithOverhang()
        setNeedsLayout()
        layoutIfNeeded()
        inner.setNeedsLayout()
        inner.layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inner.frame = bounds.insetBy(dx: border, dy: border)
    }

    /// 動いている途中の見えている形で止め、そこから次の行き先へ向かい直せるようにする。
    /// 作ったばかりでまだ一度も描いていない複製（再描画の前に行き先を測り直したとき）は、見えている形を読めない。
    /// 読めないまま止めると、行き先の値を見えている形と取り違え、行き先へ1コマで移るため、動かす前の形に戻す。
    func freezeAtPresentation() {
        guard layer.presentation() != nil else {
            Self.removeAllAnimations(in: layer)
            if let overhang {
                Self.removeAllAnimations(in: overhang.layer)
            }
            if let previousGeometry {
                apply(previousGeometry)
                self.previousGeometry = previousGeometry
            }
            for part in tileDecorationBeforeMove {
                part.view.transform = part.transform
                part.view.alpha = part.alpha
            }
            return
        }
        let presented = layer.presentation()
        let innerPresented = inner.layer.presentation()
        let size = presented?.bounds.size ?? bounds.size
        let innerSize = innerPresented?.bounds.size ?? inner.bounds.size
        let position = presented?.position ?? center
        let presentedTransform = presented.map { CATransform3DGetAffineTransform($0.transform) } ?? transform
        let radius = presented?.cornerRadius ?? layer.cornerRadius
        let innerRadius = innerPresented?.cornerRadius ?? inner.layer.cornerRadius
        let opacity = presented.map { CGFloat($0.opacity) } ?? alpha
        let partsPresented = tileDecorationParts.map { part in
            (
                view: part,
                transform: part.layer.presentation().map { CATransform3DGetAffineTransform($0.transform) } ?? part.transform,
                alpha: part.layer.presentation().map { CGFloat($0.opacity) } ?? part.alpha
            )
        }
        // 中の画像（`FocusCroppedImageView`の中の画像）も前の行き先へ動き続けるので、中まですべての動きを止め、今の大きさで並べ直す。
        Self.removeAllAnimations(in: layer)
        if let overhang {
            Self.removeAllAnimations(in: overhang.layer)
        }
        border = max((size.width - innerSize.width) / 2, 0)
        bounds = CGRect(origin: .zero, size: size)
        center = position
        transform = presentedTransform
        layer.cornerRadius = radius
        inner.layer.cornerRadius = innerRadius
        alpha = opacity
        followWithOverhang()
        for part in partsPresented {
            part.view.transform = part.transform
            part.view.alpha = part.alpha
        }
        setNeedsLayout()
        layoutIfNeeded()
        inner.setNeedsLayout()
        inner.layoutIfNeeded()
    }

    private static func removeAllAnimations(in layer: CALayer) {
        layer.removeAllAnimations()
        for sublayer in layer.sublayers ?? [] {
            removeAllAnimations(in: sublayer)
        }
    }

    func replaceThumbnailIfLarger(_ image: UIImage, focus: MediaFocus?) {
        guard let imageView = inner as? FocusCroppedImageView, image.size.width > (imageView.image?.size.width ?? 0) else { return }
        imageView.image = image
        imageView.focus = focus
    }
}
