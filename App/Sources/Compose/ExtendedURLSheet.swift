import SciaCore
import SwiftUI
import UIKit

/// URLの後ろに続いた文字を知らせるシートの、動きの時間。チューニングから読む。
struct ExtendedURLTiming: Hashable {
    var headHold: Double
    var pan: Double
    var junctionHold: Double
    var cut: Double
    var cutGap: Double
    var cutHold: Double
    var drop: Double
    var endHold: Double
    var fade: Double

    @MainActor
    init(tuning: TuningStore) {
        headHold = tuning.value(of: TuningCatalog.extendedURLHeadHold)
        pan = tuning.value(of: TuningCatalog.extendedURLPanDuration)
        junctionHold = tuning.value(of: TuningCatalog.extendedURLJunctionHold)
        cut = tuning.value(of: TuningCatalog.extendedURLCutDuration)
        cutGap = tuning.value(of: TuningCatalog.extendedURLCutGap)
        cutHold = tuning.value(of: TuningCatalog.extendedURLCutHold)
        drop = tuning.value(of: TuningCatalog.extendedURLDropDuration)
        endHold = tuning.value(of: TuningCatalog.extendedURLEndHold)
        fade = tuning.value(of: TuningCatalog.extendedURLFadeDuration)
    }
}

/// URLの後ろに続いた文字を知らせるシートの中身。決まりはdocs/compose.mdの「URLの後ろに続いた文字」にある。
/// 題でリンクに入ってしまう文字を示し、何が起きているかと改行を入れたあとの形を、繰り返す動きで見せる。
struct ExtendedURLView: View {
    let prompt: ExtendedURLPrompt
    let timing: ExtendedURLTiming
    let choose: @MainActor (ExtendedURLChoice) -> Void

    var body: some View {
        // URLが多いときや文字を大きくしたときに収まらなければ、題と動きをスクロールさせ、ボタンは下に残す。
        VStack(spacing: 16) {
            ScrollView {
                summary
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                ForEach(prompt.lines) { line in
                    ExtendedURLAnimation(line: line, timing: timing)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(prompt.accessibilityDescription)
        }
    }

    private var buttons: some View {
            VStack(spacing: 10) {
                Button { choose(.separate) } label: {
                    Text(prompt.separateTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button { choose(.postAsIs) } label: {
                    Text(prompt.postAsIsTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
    }
}

/// 1つのURLと続いた文字を、折り返さずに1行に並べ、カメラで追って切り離し、次の行へ移す動きを繰り返す。
/// 視差効果を減らす設定では、繰り返さずに、改行を入れたあとの形を止めて見せる。
private struct ExtendedURLAnimation: View {
    let line: ExtendedURLPrompt.Line
    let timing: ExtendedURLTiming
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var urlSize: CGSize = .zero
    @State private var continuationWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private static let padding: CGFloat = 14

    /// 動きの途中の1コマ。
    struct Frame {
        var opacity: Double = 0
        var cameraX: CGFloat = 0
        var cutScale: CGFloat = 0
        var cutOpacity: Double = 1
        var continuationX: CGFloat = 0
        var continuationY: CGFloat = 0
        var linkness: Double = 1
    }

    var body: some View {
        Group {
            if reduceMotion {
                content(Frame(opacity: 1, continuationY: urlSize.height, linkness: 0))
            } else {
                KeyframeAnimator(initialValue: Frame(continuationX: urlSize.width), repeating: true) { frame in
                    content(frame)
                } keyframes: { _ in
                    keyframes()
                }
                // 測り終えたら、測った幅で動きを組み直す。
                .id(Measurement(urlWidth: urlSize.width, urlHeight: urlSize.height, continuationWidth: continuationWidth, viewport: viewportWidth, timing: timing))
            }
        }
        // 中身は折り返さずに見える幅より長くなるので、最小の幅を0にして、見える幅に収めて切る。
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: max(urlSize.height, 20) * 2 + Self.padding * 2, alignment: .top)
        .clipped()
        // 枠からはみ出す文字は「…」で縮めず、余白の幅でフェードにして消す。
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.padding)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.padding)
            }
        }
        // シートはLiquid Glassで下の投稿が透けるので、URLを読みやすいよう、見本の枠は塗る。
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    private struct Measurement: Hashable {
        var urlWidth: CGFloat
        var urlHeight: CGFloat
        var continuationWidth: CGFloat
        var viewport: CGFloat
        var timing: ExtendedURLTiming
    }

    private func content(_ frame: Frame) -> some View {
        ZStack(alignment: .topLeading) {
            Text(line.url)
                .foregroundStyle(.tint)
                .underline()
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { urlSize = $0 }
            ZStack(alignment: .topLeading) {
                Text(line.continuation)
                    .foregroundStyle(.tint)
                    .underline()
                    .opacity(frame.linkness)
                Text(line.continuation)
                    .foregroundStyle(.primary)
                    .opacity(1 - frame.linkness)
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { continuationWidth = $0 }
            .offset(x: frame.continuationX, y: frame.continuationY)
            Capsule()
                .fill(.orange)
                .frame(width: 2, height: urlSize.height + 6)
                .scaleEffect(x: 1, y: frame.cutScale, anchor: .top)
                .opacity(frame.cutOpacity)
                .offset(x: urlSize.width - 1, y: -3)
        }
        .lineLimit(1)
        .font(.body)
        .offset(x: frame.cameraX)
        .padding(Self.padding)
        .opacity(frame.opacity)
    }

    /// カメラを動かして、つながっているところを止める位置。続いた文字が全部見える位置を基本に、見える幅の6割より右にも、半分より左にも行かせない。
    /// 続いた文字が短ければ6割の位置で、URLの終わりを長めに見せる。長ければ半分の位置まで寄せて、続いた文字を見える幅の半分まで見せる。
    private var junctionX: CGFloat {
        let showsWholeContinuation = viewportWidth - Self.padding - continuationWidth
        return min(viewportWidth * 0.6, max(viewportWidth * 0.5, showsWholeContinuation))
    }

    /// つながっているところが`junctionX`に来るまでカメラを動かす。続いた文字まで全体が収まれば動かさない。
    private var pan: CGFloat {
        guard urlSize.width + continuationWidth + Self.padding * 2 > viewportWidth else { return 0 }
        return max(0, Self.padding + urlSize.width - junctionX)
    }

    /// カメラがつながっているところへ動く曲線。動き始めも止まりぎわも緩める。
    private static let panCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    /// 切り離した文字が次の行の頭へ着き、カメラが戻る曲線。すぐ動き出し、着く前に緩めて止める。
    private static let landingCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 1), endControlPoint: UnitPoint(x: 0.5, y: 1))

    /// `spring`が止まりきるまでの時間。`available`までに止まりきらなければ、`available`で打ち切る。
    private static func settle(_ spring: Spring, within available: Double) -> Double {
        max(0.01, min(spring.settlingDuration, available))
    }

    @KeyframesBuilder<Frame>
    private func keyframes() -> some Keyframes<Frame> {
        let t = timing
        let snap = 0.12
        let panStart = t.fade + t.headHold
        // カメラが着いたら、つながっているのを少し見せてから切る。
        let cutStart = panStart + t.pan + t.junctionHold
        let split = cutStart + t.cut
        let dropStart = split + max(t.cutHold, snap)
        let fadeStart = dropStart + t.drop + t.endHold
        let total = fadeStart + t.fade
        // URLは止めたまま、続いた文字だけを弾いて開く。
        let gap = t.cutGap
        // 下へは横より先に着かせ、URLの行から離れてから左へ動かす。斜めに動くと、URLの行の上を横切って文字が重なるため。
        let fall = t.drop * 0.45
        let slideDelay = fall * 0.6
        let lineHeight = urlSize.height
        let urlWidth = urlSize.width

        // 繰り返すと、各値は前の周の終わりの値から始まるので、どのトラックも初めの値へ飛ばしてから始める。消えている間なので見えない。
        KeyframeTrack(\.opacity) {
            MoveKeyframe(0)
            LinearKeyframe(1, duration: t.fade)
            LinearKeyframe(1, duration: fadeStart - t.fade)
            LinearKeyframe(0, duration: t.fade)
        }
        // カメラと、続いた文字が左へ滑る動きは、長いURLでは数百ptを動くので、決まった時間でぴたりと止まる曲線で動かす。
        // スプリングは止まりぎわに少しずつ近づき続けるので、距離が長いと、止まったあとも数ptずつ動いて見えたため。
        KeyframeTrack(\.cameraX) {
            MoveKeyframe(0)
            LinearKeyframe(0, duration: panStart)
            LinearKeyframe(-pan, duration: t.pan, timingCurve: Self.panCurve)
            LinearKeyframe(-pan, duration: dropStart - panStart - t.pan)
            LinearKeyframe(0, duration: t.drop, timingCurve: Self.landingCurve)
            LinearKeyframe(0, duration: total - dropStart - t.drop)
        }
        KeyframeTrack(\.cutScale) {
            MoveKeyframe(0)
            LinearKeyframe(0, duration: cutStart)
            CubicKeyframe(1, duration: t.cut)
            LinearKeyframe(1, duration: total - split)
        }
        // 切って開くのと、下へ落ちるのは、短い距離なのでスプリングで弾ませる。止まりきるまでの時間（`settlingDuration`）をキーフレームに取り、
        // 止まりきらない残りを、次のキーフレームが直線でゆっくり詰めないようにする。
        let slideStart = dropStart + slideDelay
        let snapSpring = Spring.snappy(duration: snap, extraBounce: 0.2)
        let snapSettle = Self.settle(snapSpring, within: slideStart - split)
        let slide = t.drop - slideDelay
        KeyframeTrack(\.continuationX) {
            MoveKeyframe(urlWidth)
            LinearKeyframe(urlWidth, duration: split)
            SpringKeyframe(urlWidth + gap, duration: snapSettle, spring: snapSpring)
            // 下へ落ちてURLの行から離れてから、左へ動かす。
            LinearKeyframe(urlWidth + gap, duration: slideStart - split - snapSettle)
            LinearKeyframe(0, duration: slide, timingCurve: Self.landingCurve)
            LinearKeyframe(0, duration: total - slideStart - slide)
        }
        let fallSpring = Spring.snappy(duration: fall)
        let fallSettle = Self.settle(fallSpring, within: fadeStart - dropStart)
        KeyframeTrack(\.continuationY) {
            MoveKeyframe(0)
            LinearKeyframe(0, duration: dropStart)
            SpringKeyframe(lineHeight, duration: fallSettle, spring: fallSpring)
            LinearKeyframe(lineHeight, duration: total - dropStart - fallSettle)
        }
        KeyframeTrack(\.linkness) {
            MoveKeyframe(1)
            LinearKeyframe(1, duration: split)
            LinearKeyframe(0, duration: snap)
            LinearKeyframe(0, duration: total - split - snap)
        }
        // 線は切ったところが開いたらすぐ消し、文字が動き出すときに残さない。動く文字に線が重なって見えないようにするため。
        let lineFade = max(0.01, min(0.15, dropStart - split - snap))
        KeyframeTrack(\.cutOpacity) {
            MoveKeyframe(1)
            LinearKeyframe(1, duration: split + snap)
            LinearKeyframe(0, duration: lineFade)
            LinearKeyframe(0, duration: total - split - snap - lineFade)
        }
    }
}

/// URLの後ろに続いた文字を知らせるシート。中身の高さに合わせた1段で出す。
/// ボタンを押したら、閉じたことを知らせてから選んだものを渡し、閉じる。下へスワイプして閉じたら、閉じたことだけを知らせる。
final class ExtendedURLSheet: UIHostingController<ExtendedURLView> {
    private let onClose: () -> Void
    private var hasClosed = false

    /// - Parameter onDismissed: ボタンを押して閉じたとき、閉じ終えてから呼ぶ。
    init(prompt: ExtendedURLPrompt, timing: ExtendedURLTiming, onChoose: @escaping (ExtendedURLChoice) -> Void, onClose: @escaping () -> Void, onDismissed: @escaping () -> Void) {
        self.onClose = onClose
        // 閉じる処理は自分を参照するため、作り終えてから入れ直す。
        super.init(rootView: ExtendedURLView(prompt: prompt, timing: timing, choose: { _ in }))
        rootView = ExtendedURLView(prompt: prompt, timing: timing) { [weak self] choice in
            guard let self else { return }
            notifyClosed()
            onChoose(choice)
            dismiss(animated: true, completion: onDismissed)
        }
        sizingOptions = .preferredContentSize
        // 中身が画面に収まらなければ、シートは最大の高さで止め、中身をスクロールさせる。
        let detent = UISheetPresentationController.Detent.custom(identifier: .init("fitting")) { [weak self] context in
            self.map { min($0.preferredContentSize.height, context.maximumDetentValue) }
        }
        sheetPresentationController?.detents = [detent]
        // 閉じるボタンは置かず、掴みを出して下へスワイプして閉じさせる。
        sheetPresentationController?.prefersGrabberVisible = true
    }

    /// 出す前に、`width`の幅で中身の高さを測っておく。`preferredContentSize`は中身を並べ終えるまで0なので、測らずに出すと、
    /// シートは高さ0で出てから測った高さへ動きなしに切り替わり、下から上がる動きが見えなかったため。
    func measure(width: CGFloat) {
        preferredContentSize = sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// 中身の高さが変わったら（シートの幅で並べ直したときや、文字の大きさを変えたときなど）、シートの高さを動きで合わせ直す。
    override var preferredContentSize: CGSize {
        didSet {
            guard preferredContentSize != oldValue, let sheet = sheetPresentationController else { return }
            sheet.animateChanges {
                sheet.invalidateDetents()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
    }

    private func notifyClosed() {
        guard !hasClosed else { return }
        hasClosed = true
        onClose()
    }
}

extension ExtendedURLSheet: UIAdaptivePresentationControllerDelegate {
    /// 下へスワイプして閉じたときと、出した側からまとめて閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notifyClosed()
    }
}
