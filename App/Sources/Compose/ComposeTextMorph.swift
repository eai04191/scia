import SciaCore
import UIKit

/// 投稿欄の開閉で、本文の文字を、カプセルの1行（A）から入力欄（B）へ動かす。
///
/// どの文字を動かし、どれをその場で出し入れするかは`TextMorphPlan`が決める。ここでは、決めたかたまりを`TextLineView`で描き、
/// 写真の複製（`ComposeMorphFlights`）と同じくバーの中に重ねて、行を入れ替えるのと同じアニメーションの中で動かす。
/// 動いている間は、両方の端の本物の文字を隠す。入力欄は、そのとき入っている文字だけを隠すので、動いている途中に打った文字とカーソルはすぐ見える。
///
/// 動かすかたまりは、見える範囲の端に近づくと透明へ薄くなる入れ物に入れる。見える範囲は、Aのカプセルの行（行末はカプセルと同じ幅でぼかす）から
/// Bの入力欄の枠へ、ほかの動きと同じスプリングで移す。両端で本物の見え方と同じになり、途中で欄の端を越える文字は、端の内側で薄くなって消える。
///
/// その場で出し入れするかたまりは、入力欄の枠の入れ物に入れ、動かすかたまりのいちばん下の行と縦に揃えて動かす。行のあいだを変えないためと、
/// 本文の後半がその下の行の上を通らないようにするため。入れ物の見える範囲は、Aではカプセルの行、Bでは入力欄の枠にする。
///
/// 返信の宛先や返信先のラベルのように、Bで本文より上や左にあるものは、動く本文が空けた場所にだけ見せる。本文はカプセルの行（ラベルの来る場所）から
/// 下へ動くので、その場で浮かび上がらせるだけでは、動く本文が浮かび上がる途中の文字の上を通るため。上にあるものは、いちばん上で動く本文の上端より上、
/// 同じ行の左にあるものは、その行で動く本文の左端より左だけに見せ、境目は薄くぼかす。境目は本文と同じスプリングで動かす。
@MainActor
final class ComposeTextMorph {
    enum End {
        case a
        case b
    }

    /// 片方にしかない文字を入れ替える間合い。どちらも動きの長さに対する割合。出ていく文字を`outEnd`までに消し切り、
    /// 入ってくる文字を`outEnd`から`inEnd`までで浮かび上がらせる。
    struct Swap {
        let outEnd: Double
        let inEnd: Double
    }

    /// 開閉のどちらかの端。
    struct Side {
        let scene: TextMorphScene
        /// 入力欄の枠。Aでは、隠している入力欄が並んでいる枠。
        let field: CGRect
        /// かたまりに描く文字。両方の端で同じ属性の文字を返す。
        let text: (TextMorphPlan.Key) -> NSAttributedString?
        /// 本物の文字を隠す。Aでは動かすかたまりだけを、Bでは今ある文字をすべて隠す。空なら見せ直す。
        let conceal: ([TextMorphPlan.Key]) -> Void
    }

    /// Bで本文の上に並ぶ行（返信先のラベルなど）。動く本文が空けた場所にだけ見せる。
    var rowsAboveText: () -> [UIView] = { [] }

    /// 動く本文が空けた場所にだけ見せるときの、境目の向き。
    private enum Wipe {
        /// 境目より上だけを見せる。
        case above
        /// 境目より左だけを見せる。
        case left
    }

    /// 動かすかたまり。文字は、描くビューの中の画素の境目に揃えて描かれるので、同じ文字でも、ビューの枠を置く位置の端数が違うと違う画素に描かれる。
    /// 両方の端で本物と同じ画素に描くよう、Aの端に合わせて描く行とBの端に合わせて描く行を重ねて運び、動いている途中で行き先の端の行に入れ替える。
    private final class FlightHolder: UIView {
        /// 頭の文字のベースラインの位置に置く、大きさのない入れ物。2つの行を一緒に動かす。
        let mover = UIView()
        let lineA = TextLineView()
        let lineB = TextLineView()

        func line(at end: End) -> TextLineView {
            end == .a ? lineA : lineB
        }
    }

    /// 片方の端にしかない、1つの行のかたまり。
    private final class LineHolder: UIView {
        let line = TextLineView()
    }

    private final class StayHolder: UIView {
        let line = TextLineView()
        var wipe: Wipe?
        lazy var wipeWindow = FadeWindowView(axis: wipe == .left ? .horizontal : .vertical)
    }

    private let container: UIView
    /// 動かすかたまりの入れ物。見える範囲を縦に区切る入れ物と、その中で横に区切る入れ物で、角は縦と横の薄くし方を掛け合わせた濃さになる。
    private let flightStage = FadeStage()
    /// その場で出し入れするかたまりの入れ物。入力欄の枠に重ねる。
    private let fieldStage = FadeStage()
    private var flights: [TextMorphPlan.Key: FlightHolder] = [:]
    /// カプセルの行末。前のかたまりと一緒に動かしながら薄くする。
    private var tails: [TextMorphPlan.Key: LineHolder] = [:]
    /// カプセルにしかない文字。書いているときにしかない文字より先に消し切る。
    private var departures: [TextMorphPlan.Key: LineHolder] = [:]
    private var stays: [TextMorphPlan.Key: StayHolder] = [:]
    /// 本文の上の行にかけたマスク。
    private var rowWipes: [(row: UIView, window: FadeWindowView)] = []
    private var source: (side: Side, end: End, rowFrames: [ObjectIdentifier: CGRect])?
    /// 今の向きの両方の端。動き終えたときに本物を見せ直す。
    private var sides: (a: Side, b: Side)?
    /// 本文の上の行の、両方の端での枠。
    private var rowFrames: (a: [ObjectIdentifier: CGRect], b: [ObjectIdentifier: CGRect]) = ([:], [:])
    /// 書いているときに出している、本文の上の行。
    private var rowsShownInB: [ObjectIdentifier] = []
    private var destinationEnd: End = .b
    private var generation = 0
    /// 今隠している範囲。カーソルが動いたときに、同じ範囲で隠し直す。
    private var concealed: (a: [TextMorphPlan.Key], b: [TextMorphPlan.Key]) = ([], [])

    var isMorphing: Bool { !flights.isEmpty || !stays.isEmpty || !tails.isEmpty || !departures.isEmpty }

    init(container: UIView) {
        self.container = container
        flightStage.frame = container.bounds
        flightStage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 入れ物は隠さずに置いておく。隠した入れ物を出すのと同じ実行ループで足したかたまりは、アニメーションせずに行き先へ置かれたため。
        for stage in [fieldStage, flightStage] {
            container.addSubview(stage)
        }
    }

    /// 行を入れ替える前に、今の配置を起点として覚える。動かしている途中なら、かたまりと見える範囲を、そのとき見えている形で止める。
    func takeOff(from side: Side, at end: End) {
        if isMorphing {
            for holder in flights.values {
                Self.freeze(holder)
            }
            for holder in Array(tails.values) + Array(departures.values) {
                Self.freeze(holder)
            }
            for holder in stays.values {
                Self.freeze(holder)
            }
            for wipe in rowWipes {
                Self.freeze(wipe.window)
            }
            flightStage.freezeWindow()
            fieldStage.freezeWindow()
            Self.freeze(fieldStage)
        } else {
            UIView.performWithoutAnimation {
                self.flightStage.setWindow(side.scene.window, fade: side.scene.fade)
            }
        }
        source = (side, end, measureRows())
        if end == .b {
            rowsShownInB = rowsAboveText().filter { !$0.isHidden }.map(ObjectIdentifier.init)
        }
    }

    private func measureRows() -> [ObjectIdentifier: CGRect] {
        Dictionary(uniqueKeysWithValues: rowsAboveText().map { row in
            (ObjectIdentifier(row), row.superview?.convert(row.frame, to: container) ?? row.frame)
        })
    }

    /// 行を入れ替えて並べ直したあと、同じアニメーションの中で呼ぶ。かたまりを行き先へ動かし、見える範囲を行き先の枠へ移す。返した値を`finish`に渡す。
    /// `duration`は動きの長さ、`swap`は片方にしかない文字を入れ替える間合い。
    func land(on side: Side, duration: TimeInterval, swap: Swap) -> Int? {
        guard let source else { return nil }
        self.source = nil
        let end: End = source.end == .a ? .b : .a
        let a = source.end == .a ? source.side : side
        let b = source.end == .b ? source.side : side
        let measured = measureRows()
        rowFrames = source.end == .a ? (source.rowFrames, measured) : (measured, source.rowFrames)
        if end == .b {
            rowsShownInB = rowsAboveText().filter { !$0.isHidden }.map(ObjectIdentifier.init)
        }
        let plan = TextMorphPlan(a: a.scene, b: b.scene)
        let wasMorphing = isMorphing
        generation += 1
        sides = (a, b)
        destinationEnd = end
        for stage in [fieldStage, flightStage] {
            container.bringSubviewToFront(stage)
        }
        var placed: Set<TextMorphPlan.Key> = []
        UIView.performWithoutAnimation {
            for flight in plan.flights {
                placed.insert(flight.key)
                if flights[flight.key] == nil, let text = b.text(flight.key) ?? a.text(flight.key) {
                    let holder = FlightHolder()
                    for line in [holder.lineA, holder.lineB] {
                        Self.configure(line, text: text)
                        holder.mover.addSubview(line)
                    }
                    holder.addSubview(holder.mover)
                    flightStage.content.addSubview(holder)
                    flights[flight.key] = holder
                    holder.mover.center = source.end == .a ? flight.originInA : flight.originInB
                    holder.line(at: end).alpha = 0
                }
                guard let holder = flights[flight.key] else { continue }
                align(holder.lineA, at: .zero, landingAt: flight.originInA)
                align(holder.lineB, at: .zero, landingAt: flight.originInB)
            }
            for tail in plan.tails {
                guard tails[tail.key] == nil, let text = a.text(tail.key) else { continue }
                let holder = LineHolder()
                Self.configure(holder.line, text: text)
                holder.addSubview(holder.line)
                flightStage.content.addSubview(holder)
                tails[tail.key] = holder
                align(holder.line, at: Self.origin(of: tail, at: source.end, plan: plan), landingAt: tail.originInA)
                holder.line.alpha = source.end == .a ? 1 : 0
            }
            for departure in plan.departures {
                guard departures[departure.key] == nil, let text = a.text(departure.key) else { continue }
                let holder = LineHolder()
                Self.configure(holder.line, text: text)
                holder.addSubview(holder.line)
                flightStage.content.addSubview(holder)
                departures[departure.key] = holder
                align(holder.line, at: departure.originInA)
                holder.line.alpha = source.end == .a ? 1 : 0
            }
            for stay in plan.stays {
                placed.insert(stay.key)
                guard stays[stay.key] == nil else { continue }
                addStay(stay, plan: plan, b: b)?.line.alpha = source.end == .b ? 1 : 0
            }
            if !wasMorphing {
                applyField(at: source.end, plan: plan)
                attachRowWipes()
                if !plan.departures.isEmpty {
                    for wipe in rowWipes {
                        wipe.window.alpha = source.end == .b ? 1 : 0
                    }
                }
                applyWipes(at: source.end, plan: plan)
            }
            conceal(a: a, b: b, plan: plan)
        }
        for flight in plan.flights {
            guard let holder = flights[flight.key] else { continue }
            holder.mover.center = end == .a ? flight.originInA : flight.originInB
            holder.alpha = 1
            Self.handOver(from: holder.line(at: source.end), to: holder.line(at: end), duration: duration, swap: swap)
        }
        // カプセルにしかない文字があれば、それを先に消し切り、書いているときにしかない文字はそのあとで浮かび上がらせる（閉じるときは逆）。
        // 同じ場所に出入りするので、同時に薄くしたり濃くしたりすると重なって見えるため。
        // 行末と同じ文字も、行末と入れ替わりに出入りさせる。
        let staged = !plan.departures.isEmpty
        let stagedStays = plan.stays.filter { stay in staged || plan.tails.contains { $0.key.content == stay.key.content && $0.key.range.clamped(to: stay.key.range) == stay.key.range } }
        Self.stage(!stagedStays.isEmpty, appearing: end == .b, duration: duration, swap: swap) { shown in
            for stay in stagedStays {
                self.stays[stay.key]?.line.alpha = shown ? 1 : 0
            }
        }
        for stay in plan.stays where !stagedStays.contains(stay) {
            stays[stay.key]?.line.alpha = end == .b ? 1 : 0
        }
        Self.stage(staged, appearing: end == .b, duration: duration, swap: swap) { shown in
            for wipe in self.rowWipes {
                wipe.window.alpha = shown ? 1 : 0
            }
        }
        Self.stage(staged, appearing: end == .a, duration: duration, swap: swap) { shown in
            for departure in plan.departures {
                self.departures[departure.key]?.line.alpha = shown ? 1 : 0
            }
        }
        for tail in plan.tails {
            guard let holder = tails[tail.key] else { continue }
            Self.place(holder.line, at: Self.origin(of: tail, at: end, plan: plan))
            // 行末は、同じ文字が入力欄の次の行に浮かび上がるので、開くときは先に消し切り、閉じるときはあとで浮かび上がらせる。
            // 両方が半分ずつ見えて、同じ文字が2か所に見えないようにするため。
            Self.stage(true, appearing: end == .a, duration: duration, swap: swap) { shown in
                holder.line.alpha = shown ? 1 : 0
            }
        }
        for (key, holder) in tails where !plan.tails.contains(where: { $0.key == key }) {
            holder.line.alpha = 0
        }
        // 前の向きで動かしていて、今の計画にないかたまりは、その場で薄くする。
        for (key, holder) in flights where !placed.contains(key) {
            holder.alpha = 0
        }
        for (key, holder) in stays where !placed.contains(key) {
            holder.line.alpha = 0
        }
        apply(at: end, plan: plan)
        return generation
    }

    @discardableResult
    private func addStay(_ stay: TextMorphPlan.Stay, plan: TextMorphPlan, b: Side) -> StayHolder? {
        guard let text = b.text(stay.key) else { return nil }
        let holder = StayHolder()
        Self.configure(holder.line, text: text)
        holder.addSubview(holder.line)
        holder.wipe = wipe(of: stay, plan: plan)
        if holder.wipe != nil {
            holder.mask = holder.wipeWindow
        }
        fieldStage.content.addSubview(holder)
        stays[stay.key] = holder
        align(holder.line, at: Self.local(stay.originInB, in: b.field))
        return holder
    }

    /// 行き先の行が次の実行ループで並べ直されたときに、行き先と見える範囲を測り直して向かい直す。`animation`は残りの時間で動かす。
    /// 開き始めは、入力欄がまだ文字に合わせた高さになっていないことがあるため。
    func retarget(on side: Side, generation: Int, animation: (@escaping () -> Void) -> Void) {
        guard generation == self.generation, let sides else { return }
        let a = destinationEnd == .a ? side : sides.a
        let b = destinationEnd == .b ? side : sides.b
        let previous = destinationEnd == .a ? sides.a : sides.b
        let measured = measureRows()
        let previousRows = destinationEnd == .a ? rowFrames.a : rowFrames.b
        guard side.scene != previous.scene || side.field != previous.field || measured != previousRows else { return }
        self.sides = (a, b)
        if destinationEnd == .a {
            rowFrames.a = measured
        } else {
            rowFrames.b = measured
        }
        let plan = TextMorphPlan(a: a.scene, b: b.scene)
        // 測り直して、新しく見える行（スクロールした入力欄など）ができたら、その行のかたまりも作る。見えなくなった行は薄くする。
        var appeared: [StayHolder] = []
        UIView.performWithoutAnimation {
            // 行き先の端に合わせて描く行を、測り直した位置に合わせ直す。
            for flight in plan.flights {
                guard let holder = flights[flight.key] else { continue }
                align(holder.line(at: destinationEnd), at: .zero, landingAt: destinationEnd == .a ? flight.originInA : flight.originInB)
            }
            // その場で出し入れするかたまりは、入力欄の枠の中の位置に置き直す。
            for stay in plan.stays {
                if let holder = stays[stay.key] {
                    align(holder.line, at: Self.local(stay.originInB, in: b.field))
                } else if let holder = addStay(stay, plan: plan, b: b) {
                    holder.line.alpha = 0
                    appeared.append(holder)
                }
            }
            conceal(a: a, b: b, plan: plan)
        }
        let destination = destinationEnd
        let moves = plan.flights.compactMap { flight -> (view: UIView, move: () -> Void)? in
            flights[flight.key].map { holder in (holder.mover, { holder.mover.center = destination == .a ? flight.originInA : flight.originInB }) }
        } + plan.tails.compactMap { tail -> (view: UIView, move: () -> Void)? in
            tails[tail.key].map { holder in (holder.line, { Self.place(holder.line, at: Self.origin(of: tail, at: destination, plan: plan)) }) }
        } + plan.departures.compactMap { departure -> (view: UIView, move: () -> Void)? in
            departures[departure.key].map { holder in (holder.line, { Self.place(holder.line, at: departure.originInA) }) }
        }
        // 位置と大きさだけを止める。濃さの動き（浮かび上がらせる、行末を薄くするなど）は、止めずにそのまま続ける。
        for move in moves {
            Self.freezePosition(move.view)
        }
        for holder in stays.values {
            Self.freezePosition(holder)
        }
        for wipe in rowWipes {
            Self.freezePosition(wipe.window)
        }
        // 動かすかたまりの入れ物は、バーの中身に合わせて伸び縮みさせたまま止めない。止めると、止めたときの大きさのまま残り、
        // 着いて本物に替えたコマで、文字が1画素ずれた。見える範囲だけを止める。
        flightStage.freezeWindowPosition()
        fieldStage.freezeWindowPosition()
        Self.freezePosition(fieldStage, includingSubviews: false)
        let gone = stays.filter { key, _ in !plan.stays.contains { $0.key == key } }.map(\.value)
        let appearedAlpha: CGFloat = destinationEnd == .b ? 1 : 0
        animation {
            for move in moves {
                move.move()
            }
            for holder in appeared {
                holder.line.alpha = appearedAlpha
            }
            for holder in gone {
                holder.line.alpha = 0
            }
            self.apply(at: self.destinationEnd, plan: plan)
        }
    }

    private func conceal(a: Side, b: Side, plan: TextMorphPlan) {
        concealed = (plan.concealedInA, plan.concealedInB)
        a.conceal(concealed.a)
        b.conceal(concealed.b)
    }

    /// 同じ範囲で本物を隠し直す。入力欄のカーソルが動いたときに呼ぶ。入力欄は、隠すときにカーソルを避けるため。
    func refreshConcealment() {
        guard isMorphing, let sides else { return }
        sides.a.conceal(concealed.a)
        sides.b.conceal(concealed.b)
    }

    /// 入力欄（B）の文字の行が、動き始めに測った行のまま残っているか。測った行は、同じ頭の文字から同じ位置に並び、末尾に打ち足した分だけ長くなっていてよい。
    /// 打ち足した文字は、測った行の穴の外に並ぶので、すぐ見える。折り返しが変わると、本物の文字が穴の中で動き、かたまりは前の文字のまま残る。
    /// 行の途中に打ったかは、行の範囲では分からないことがある（最後の行の途中に打つと、その行が伸びるだけになる）ので、呼ぶ側で本文と比べる。
    func keepsLines(of field: Side) -> Bool {
        guard let sides else { return true }
        return sides.b.scene.lines.allSatisfy { line in
            field.scene.lines.contains {
                $0.content == line.content && $0.range.lowerBound == line.range.lowerBound && $0.range.upperBound >= line.range.upperBound
                    && abs($0.origin.x - line.origin.x) < 0.01 && abs($0.origin.y - line.origin.y) < 0.01
            }
        }
    }

    /// 今の動きを待たずに、かたまりを外して本物を見せる。動いている途中に本文の行が変わり、かたまりで本物を描けなくなったときに呼ぶ。
    func finishNow() {
        finish(generation: generation)
    }

    /// 動き終えたら、かたまりを外して本物を見せる。途中で向きを変えていたら、新しい向きの動きが終えるまで残す。
    func finish(generation: Int) {
        guard generation == self.generation else { return }
        for holder in flights.values {
            holder.removeFromSuperview()
        }
        for holder in Array(tails.values) + Array(departures.values) {
            holder.removeFromSuperview()
        }
        for holder in stays.values {
            holder.removeFromSuperview()
        }
        flights = [:]
        tails = [:]
        departures = [:]
        stays = [:]
        for wipe in rowWipes {
            wipe.row.mask = nil
        }
        rowWipes = []
        sides?.a.conceal([])
        sides?.b.conceal([])
        sides = nil
    }

    private static func configure(_ view: TextLineView, text: NSAttributedString) {
        view.overhang = 6
        view.attributedText = text
        view.bounds = CGRect(origin: .zero, size: view.intrinsicContentSize)
    }

    /// `staged`なら、出入りを`swap`の間合いに寄せる。消すときは`outEnd`までに消し切り、浮かび上がらせるときは`outEnd`から`inEnd`まで。
    /// そうでなければ、そのときのアニメーションの中で行う。
    /// 浮かび上がらせるときも、`outEnd`まではまず消し切る。途中で向きを変えて、薄くなりかけのものを浮かび上がらせ直すとき、
    /// そのままの濃さで残って、先に消し切るはずのものと同時に見えないようにするため。
    /// 欄の形の動きはスプリングで始めのほうに寄るので、消し切る時点を4割、浮かび上がり始める時点を6割にしていたときは、欄が開き切ってから中身が出るまで空の欄が見えた。
    private static func stage(_ staged: Bool, appearing: Bool, duration: TimeInterval, swap: Swap, _ set: @escaping (Bool) -> Void) {
        guard staged else {
            set(appearing)
            return
        }
        let outEnd = min(max(swap.outEnd, 0), 1)
        let inEnd = min(max(swap.inEnd, outEnd), 1)
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .overrideInheritedDuration, .calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: outEnd) {
                set(false)
            }
            if appearing {
                UIView.addKeyframe(withRelativeStartTime: outEnd, relativeDuration: inEnd - outEnd) {
                    set(true)
                }
            }
        }
    }

    /// 動かすかたまりの2つの行を、出発の端に合わせて描く行から、行き先の端に合わせて描く行へ入れ替える。間合いは片方にしかない文字の入れ替えと同じ。
    /// 先に行き先の行を出発の行の下で濃くし、そのあとで出発の行を薄くする。同時に入れ替えると、両方が半分ずつの濃さになり、途中で文字が薄く見えるため。
    private static func handOver(from: TextLineView, to: TextLineView, duration: TimeInterval, swap: Swap) {
        from.superview?.bringSubviewToFront(from)
        let outEnd = min(max(swap.outEnd, 0), 1)
        let inEnd = min(max(swap.inEnd, outEnd), 1)
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .overrideInheritedDuration, .calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: outEnd) {
                to.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: outEnd, relativeDuration: inEnd - outEnd) {
                from.alpha = 0
            }
        }
    }

    /// 行末の`end`の端での位置。Bでは、一緒に動かすかたまりと同じだけずらした位置。
    private static func origin(of tail: TextMorphPlan.Tail, at end: End, plan: TextMorphPlan) -> CGPoint {
        guard end == .b, let follows = plan.flights.first(where: { $0.key == tail.follows }) else { return tail.originInA }
        return CGPoint(x: tail.originInA.x + follows.originInB.x - follows.originInA.x, y: tail.originInA.y + follows.originInB.y - follows.originInA.y)
    }

    /// かたまりの頭の文字のベースラインが`origin`に来るよう置き、`landingAt`（省略すると`origin`）に置いたときに、本物と同じ画素に描くよう合わせる。
    /// `origin`と`landingAt`は、入れ物の中の位置。動かすかたまりの行は、入れ物（`mover`）の中の`origin`に置き、入れ物がその端に着いた位置を`landingAt`に渡す。
    /// TextKitは、文字を描くビューの中で、画素の境目に揃えて描く（確かめた範囲では、端数を切り捨てた位置に描いた）。本物は画素の境目に置いたビューに描いているので、
    /// かたまりも枠を画素の境目に置き、本物との端数は`phase`で描く位置をずらして受け持つ。枠を端数の位置に置くと、本物と同じ位置に置いても、着いて本物に替えたコマで文字が1画素ずれた。
    private func align(_ view: TextLineView, at origin: CGPoint, landingAt landing: CGPoint? = nil) {
        let landing = landing ?? origin
        let scale = container.traitCollection.displayScale
        view.phase = .zero
        let base = view.baselineOrigin
        let corner = CGPoint(x: landing.x - base.x, y: landing.y - base.y)
        // 計算の誤差で境目のわずかに手前になっても、境目に揃える。
        let snapped = CGPoint(x: (corner.x * scale + 0.001).rounded(.down) / scale, y: (corner.y * scale + 0.001).rounded(.down) / scale)
        view.phase = CGPoint(x: corner.x - snapped.x, y: corner.y - snapped.y)
        Self.place(view, at: origin)
    }

    /// かたまりの頭の文字のベースラインが`origin`に来るよう置く。描く位置のずれ（`phase`）は変えない。
    private static func place(_ view: TextLineView, at origin: CGPoint) {
        let baseline = view.baselineOrigin
        view.center = CGPoint(x: origin.x - baseline.x + view.bounds.midX, y: origin.y - baseline.y + view.bounds.midY)
    }

    private static func local(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// 動かすかたまりの見える範囲、その場で出し入れするかたまりの入れ物、空けた場所にだけ見せる境目を、`end`の端のものにする。
    private func apply(at end: End, plan: TextMorphPlan) {
        guard let sides else { return }
        let scene = end == .a ? sides.a.scene : sides.b.scene
        flightStage.setWindow(scene.window, fade: scene.fade)
        applyField(at: end, plan: plan)
        applyWipes(at: end, plan: plan)
    }

    /// その場で出し入れするかたまりの入れ物の、`end`の端での枠。Bでは入力欄の枠。Aでは、動かすかたまりのいちばん下の行と同じだけ縦にずらす。
    private func fieldFrame(at end: End, plan: TextMorphPlan) -> CGRect {
        guard let sides else { return .zero }
        let b = sides.b
        guard end == .a else { return b.field }
        guard let anchor = plan.flights.max(by: { $0.originInB.y < $1.originInB.y }) else { return sides.a.field }
        return b.field.offsetBy(dx: 0, dy: anchor.originInA.y - anchor.originInB.y)
    }

    private func applyField(at end: End, plan: TextMorphPlan) {
        guard let sides else { return }
        let b = sides.b
        let frame = fieldFrame(at: end, plan: plan)
        fieldStage.frame = frame
        // 横は入力欄の見える範囲のまま、縦はAならカプセルの行、Bなら入力欄の枠で区切る。
        let scene = end == .a ? sides.a.scene : b.scene
        let vertical = end == .a ? scene.window.minY ... scene.window.maxY : frame.minY ... frame.maxY
        let window = CGRect(x: b.scene.window.minX - frame.minX, y: vertical.lowerBound - frame.minY, width: b.scene.window.width, height: vertical.upperBound - vertical.lowerBound)
        fieldStage.setWindow(window, fade: TextMorphFade(top: scene.fade.top, left: b.scene.fade.left, bottom: scene.fade.bottom, right: b.scene.fade.right))
    }

    /// その場で出し入れするかたまりを、動く本文が空けた場所にだけ見せるか。Bで、いちばん上の動く本文より上の行にあれば上、
    /// 動く本文と同じ行のその左にあれば左。
    private func wipe(of stay: TextMorphPlan.Stay, plan: TextMorphPlan) -> Wipe? {
        guard let top = plan.flights.min(by: { $0.originInB.y < $1.originInB.y }) else { return nil }
        if stay.originInB.y < top.originInB.y - 0.5 {
            return .above
        }
        let sameLine = plan.flights.contains { abs($0.originInB.y - stay.originInB.y) < 0.5 && $0.originInB.x > stay.originInB.x }
        return sameLine ? .left : nil
    }

    /// 境目の幅。
    private static let wipeFade: CGFloat = 6

    private func attachRowWipes() {
        for wipe in rowWipes {
            wipe.row.mask = nil
        }
        rowWipes = []
        guard let sides, !sides.b.scene.lines.isEmpty else { return }
        // 書いているときに出す行だけにかける。開き始めは、出したばかりの行がまだ高さ0で並んでいることがあるので、高さでは決めない。
        for row in rowsAboveText() where rowsShownInB.contains(ObjectIdentifier(row)) {
            let window = FadeWindowView(axis: .vertical)
            row.mask = window
            rowWipes.append((row, window))
        }
    }

    /// 空けた場所にだけ見せる境目を、`end`の端のものにする。
    private func applyWipes(at end: End, plan: TextMorphPlan) {
        guard let sides, let top = plan.flights.min(by: { $0.originInB.y < $1.originInB.y }), let topView = flights[top.key]?.lineB else {
            // 動く本文がなければ、境目を置かずにすべて見せる。
            for wipe in rowWipes {
                wipe.window.set(range: -5000 ... 5000, leadingFade: 0, trailingFade: 0, across: Self.everywhere)
            }
            return
        }
        let frame = fieldFrame(at: end, plan: plan)
        let shift = frame.minY - sides.b.field.minY
        let origin = { (flight: TextMorphPlan.Flight) in end == .a ? flight.originInA : flight.originInB }
        let topEdge = origin(top).y - topView.ascent
        var rowEdge = topEdge
        for (key, holder) in stays {
            guard let stay = plan.stays.first(where: { $0.key == key }), let wipe = holder.wipe else { continue }
            switch wipe {
            case .above:
                // 境目の下をぼかす。上の行の文字は境目の上で終わるので、着いたときに切れない。
                let edge = topEdge - frame.minY
                holder.wipeWindow.set(range: -5000 ... edge + Self.wipeFade, leadingFade: 0, trailingFade: Self.wipeFade, across: Self.everywhere)
                rowEdge = min(rowEdge, stay.originInB.y - holder.line.ascent + shift)
            case .left:
                guard let flight = plan.flights.filter({ abs($0.originInB.y - stay.originInB.y) < 0.5 && $0.originInB.x > stay.originInB.x }).min(by: { $0.originInB.x < $1.originInB.x }) else { continue }
                // 境目の左をぼかす。宛先の後ろには空白があるので、着いたときに文字は切れない。
                let edge = origin(flight).x - frame.minX
                holder.wipeWindow.set(range: -5000 ... edge, leadingFade: 0, trailingFade: Self.wipeFade / 2, across: Self.everywhere)
            }
        }
        let rows = end == .a ? rowFrames.a : rowFrames.b
        for wipe in rowWipes {
            guard let rowFrame = rows[ObjectIdentifier(wipe.row)] else { continue }
            // 境目の上をぼかす。上の行は、着いたときには本文より上で終わっている。
            wipe.window.set(range: -5000 ... rowEdge - rowFrame.minY, leadingFade: 0, trailingFade: Self.wipeFade, across: Self.everywhere)
        }
    }

    private static let everywhere = CGRect(x: -5000, y: -5000, width: 10000, height: 10000)

    /// 動かしている途中のビューの位置と大きさを、そのとき見えている形で止める。`includingSubviews`なら、子のビューとマスクも止める。濃さの動きは残す。
    static func freezePosition(_ view: UIView, includingSubviews: Bool = true) {
        if let presentation = view.layer.presentation() {
            view.layer.position = presentation.position
            view.layer.bounds = presentation.bounds
            for key in view.layer.animationKeys() ?? [] where key.hasPrefix("position") || key.hasPrefix("bounds") {
                view.layer.removeAnimation(forKey: key)
            }
        }
        guard includingSubviews else { return }
        for subview in view.subviews + [view.mask].compactMap({ $0 }) {
            freezePosition(subview)
        }
    }

    /// 動かしている途中のビューを、そのとき見えている形で止める。子のビューも止める。
    /// まだ一度も描かれていない（動きを足したのと同じ実行ループの）ビューは、動きが始まっていないので止めない。止めると、動きを外して行き先へ飛ぶ。
    static func freeze(_ view: UIView) {
        guard let presentation = view.layer.presentation() else { return }
        view.layer.position = presentation.position
        view.layer.bounds = presentation.bounds
        view.layer.opacity = presentation.opacity
        view.layer.removeAllAnimations()
        for subview in view.subviews {
            freeze(subview)
        }
    }
}

/// 見える範囲の端に近づくと、中のビューを透明へ薄くする入れ物。縦に区切るマスクの中に、横に区切るマスクの入れ物を重ねる。
private final class FadeStage: UIView {
    let content = UIView()
    private let verticalWindow = FadeWindowView(axis: .vertical)
    private let horizontalWindow = FadeWindowView(axis: .horizontal)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
        mask = verticalWindow
        content.mask = horizontalWindow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `window`の外を透明にし、内側へ`fade`の幅で濃くする。座標はこの入れ物の中のもの。
    func setWindow(_ window: CGRect, fade: TextMorphFade) {
        let across = CGRect(x: -2000, y: -2000, width: 4000 + max(bounds.width, window.maxX), height: 4000 + max(bounds.height, window.maxY))
        verticalWindow.set(range: window.minY ... max(window.minY, window.maxY), leadingFade: fade.top, trailingFade: fade.bottom, across: across)
        horizontalWindow.set(range: window.minX ... max(window.minX, window.maxX), leadingFade: fade.left, trailingFade: fade.right, across: across)
    }

    func freezeWindow() {
        ComposeTextMorph.freeze(verticalWindow)
        ComposeTextMorph.freeze(horizontalWindow)
    }

    /// 見える範囲の位置と大きさだけを止める。
    func freezeWindowPosition() {
        ComposeTextMorph.freezePosition(verticalWindow)
        ComposeTextMorph.freezePosition(horizontalWindow)
    }
}

/// 見える範囲を1つの向きで区切るマスク。範囲の両端から内側へ、決めた幅で透明から濃くする。範囲と幅を変えると、アニメーションの中で動く。
final class FadeWindowView: UIView {
    enum Axis {
        case horizontal
        case vertical
    }

    private let axis: Axis
    private let leading = GradientView()
    private let middle = UIView()
    private let trailing = GradientView()
    private var leadingFade: CGFloat = 0
    private var trailingFade: CGFloat = 0

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        middle.backgroundColor = .black
        for (gradient, isLeading) in [(leading, true), (trailing, false)] {
            gradient.gradient?.colors = isLeading ? [UIColor.clear.cgColor, UIColor.black.cgColor] : [UIColor.black.cgColor, UIColor.clear.cgColor]
            gradient.gradient?.startPoint = .zero
            gradient.gradient?.endPoint = axis == .horizontal ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1)
        }
        for view in [leading, middle, trailing] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `range`の外は透明にする。`across`は、もう一方の向きに覆う範囲。
    func set(range: ClosedRange<CGFloat>, leadingFade: CGFloat, trailingFade: CGFloat, across: CGRect) {
        let length = range.upperBound - range.lowerBound
        self.leadingFade = min(leadingFade, length / 2)
        self.trailingFade = min(trailingFade, length / 2)
        frame = axis == .horizontal
            ? CGRect(x: range.lowerBound, y: across.minY, width: length, height: across.height)
            : CGRect(x: across.minX, y: range.lowerBound, width: across.width, height: length)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let length = axis == .horizontal ? bounds.width : bounds.height
        let parts = [(leading, 0, leadingFade), (middle, leadingFade, length - leadingFade - trailingFade), (trailing, length - trailingFade, trailingFade)]
        for (view, start, size) in parts {
            view.frame = axis == .horizontal
                ? CGRect(x: start, y: 0, width: max(size, 0), height: bounds.height)
                : CGRect(x: 0, y: start, width: bounds.width, height: max(size, 0))
        }
    }
}

private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer? { layer as? CAGradientLayer }
}
