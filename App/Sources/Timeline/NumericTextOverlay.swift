import SwiftUI
import UIKit

/// UIKitのラベルの上に重ね、ラベルの文字が替わったときに、変わった数字だけを入れ替えて見せる（SwiftUIの`numericText(value:)`）。
/// UIKitの`UILabel`には、数字だけを入れ替える動きがないため。
///
/// ふだんはラベル（`underlay`）が文字を描き、入れ替わっている間だけ、ラベルの文字を透明にしてSwiftUIの`Text`に描かせる。
/// SwiftUIの表示は、初めて入れ替えるときに作り、制約ではなく枠で置く。行ごとにSwiftUIの表示を置いて並べると、
/// 隠していても、投票を並べた一覧を流したときに落ちるフレームが倍ほどに増えたため（シミュレーターで測った）。
/// 大きさと読み上げは、いつもラベルに任せる。行の高さを測るのはUIKitの並べ方なので、SwiftUIに大きさを決めさせると、測った高さと描いた高さがずれるため。
final class NumericTextOverlay: UIView {
    /// 枠の中で、文字を寄せる向き。
    enum TextAlignment {
        case leading
        case trailing

        fileprivate var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .trailing: .trailing
            }
        }
    }

    private let model = NumericTextModel()
    private let alignment: TextAlignment
    /// 数字を入れ替える間だけ描く、SwiftUIの表示。初めて入れ替えるときに作る。
    private var hosting: UIHostingController<NumericTextContent>?
    /// 次に始める入れ替わり。タイムラインは行の中身を動きを止めた描き直しの中で当てるため、`setText`の中では始めない。
    private var pending: (text: String, value: Double, duration: TimeInterval, delay: TimeInterval)?
    /// 重ねたラベル。
    private weak var underlay: UILabel?
    /// 寄せる向きと反対の側の端の制約と、ふだん広げる幅。
    private var slackConstraint: NSLayoutConstraint?
    private var slack: CGFloat = 0
    /// 入れ替わる間に保つ枠の幅。入れ替わる前の枠の幅で、入れ替わり終えたらnilに戻す。
    /// 下のラベルは先に新しい文字の幅になるので、文字が短くなると、入れ替わる途中の前の文字（「残り10秒」の「10」）が切り詰められるため。
    private var transitionWidth: CGFloat?
    private var font = UIFont.preferredFont(forTextStyle: .body)
    private var color = UIColor.label
    /// 最後に当てた文字と、その数。入れ替わりの途中なら、入れ替わった先のもの。
    private(set) var text = ""
    private var value: Double = 0
    /// 入れ替わっている途中で、SwiftUIに描かせている。
    private(set) var isTransitioning = false
    /// 最後に文字を替えたときの動きの時間。動かさずに替えたらnil。テストで、数字を動かして替えたかを確かめるために使う。
    private(set) var lastTransition: TimeInterval?

    init(alignment: TextAlignment) {
        self.alignment = alignment
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    /// SwiftUIの表示。なければ作る。
    private func loadedHosting() -> UIHostingController<NumericTextContent> {
        if let hosting { return hosting }
        let made = UIHostingController(rootView: NumericTextContent(model: model, alignment: alignment.frameAlignment))
        let content: UIView = made.view
        content.backgroundColor = .clear
        // 枠はUIKitの並べ方で決め、SwiftUIには、その枠の中に描かせる。制約で並べると、行の高さを測るたびにSwiftUIへ大きさを聞くため、枠で置く。
        made.sizingOptions = []
        made.safeAreaRegions = []
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
        hosting = made
        return made
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `label`の上に重ね、同じ枠に置く。
    /// 寄せる向きと反対の側だけ、枠を`slack`だけ広げる。SwiftUIの`Text`は、同じ文字でもUILabelが測った幅より少し広い幅を要ることがあり、
    /// 同じ幅では「10人・残り4時間」が「10人・残り4…」と切り詰められたため。寄せる側は広げないので、文字の位置はラベルと同じになる。
    func overlay(on label: UILabel, slack: CGFloat = 4) {
        guard let container = label.superview else { preconditionFailure("重ねるラベルを先に置いてください") }
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        underlay = label
        self.slack = slack
        let leading = leadingAnchor.constraint(equalTo: label.leadingAnchor)
        let trailing = trailingAnchor.constraint(equalTo: label.trailingAnchor)
        slackConstraint = alignment == .leading ? trailing : leading
        NSLayoutConstraint.activate([
            leading,
            trailing,
            topAnchor.constraint(equalTo: label.topAnchor),
            bottomAnchor.constraint(equalTo: label.bottomAnchor),
        ])
        applySlack(slack)
    }

    /// 寄せる向きと反対の側へ、枠を`width`だけ広げる。
    private func applySlack(_ width: CGFloat) {
        slackConstraint?.constant = alignment == .leading ? width : -width
    }

    /// 文字の形と色。ラベルにも当てる。動かさずに替える。
    func setStyle(font: UIFont, color: UIColor) {
        guard font != self.font || color != self.color || underlay?.font != font else { return }
        self.font = font
        self.color = color
        underlay?.font = font
        underlay?.textColor = isTransitioning ? .clear : color
        guard isTransitioning else { return }
        withoutAnimation {
            model.font = font
            model.color = color
        }
    }

    /// 文字を当てる。ラベルの文字も替える。`animation`があれば、次に`startPendingTransition()`を呼んだときに、その時間で数字を入れ替える。
    /// `value`は入れ替わる向きを決める数で、増えたら上へ、減ったら下へ動く。
    func setText(_ text: String, value: Double, animation: (duration: TimeInterval, delay: TimeInterval)?) {
        guard text != self.text else { return }
        underlay?.text = text.isEmpty ? nil : text
        let old = (text: self.text, value: self.value)
        self.text = text
        self.value = value
        guard let animation, animation.duration > 0 else {
            cancelTransition()
            return
        }
        pending = (text, value, animation.duration, animation.delay)
        transitionWidth = max(transitionWidth ?? 0, bounds.width)
        // ラベルは先に新しい文字になるので、始めるまでの間も、SwiftUIに前の文字を描かせておく。
        if !isTransitioning {
            beginTransition(showing: old.text, value: old.value)
        }
    }

    /// ラベルの文字を透明にし、SwiftUIに`text`を描かせる。
    private func beginTransition(showing text: String, value: Double) {
        isTransitioning = true
        withoutAnimation {
            model.font = font
            model.color = color
            model.text = text
            model.value = value
        }
        loadedHosting().view.isHidden = false
        underlay?.textColor = .clear
    }

    /// SwiftUIの文字を隠し、ラベルに描かせる。
    private func endTransition() {
        isTransitioning = false
        transitionWidth = nil
        applySlack(slack)
        hosting?.view.isHidden = true
        underlay?.textColor = color
    }

    /// `setText`で決めた入れ替わりを始める。並べ終えてから呼ぶ。
    func startPendingTransition() {
        guard let pending else { return }
        self.pending = nil
        lastTransition = pending.duration
        if let width = transitionWidth, let underlay {
            superview?.layoutIfNeeded()
            applySlack(max(slack, width - underlay.bounds.width))
        }
        let generation = model.generation
        withAnimation(.smooth(duration: pending.duration).delay(pending.delay), completionCriteria: .removed) {
            model.text = pending.text
            model.value = pending.value
        } completion: { [weak self] in
            // 入れ替わり終えたら、ラベルに戻す。後に続く入れ替わりや作り直しがあれば、そちらに任せる。
            guard let self, model.generation == generation, self.pending == nil else { return }
            endTransition()
        }
    }

    /// 入れ替わりをやめ、今の文字のまま止める。
    func cancelTransition() {
        pending = nil
        lastTransition = nil
        guard isTransitioning else { return }
        // 同じ値を入れ直すだけでは、SwiftUIで続いている入れ替わりは止まらない。表示を作り直して止める。
        withoutAnimation {
            model.generation += 1
        }
        endTransition()
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

/// `NumericTextOverlay`の文字。UIKitの部品が当て、SwiftUIの`NumericTextContent`が描く。
@MainActor
@Observable
final class NumericTextModel {
    var text = ""
    var value: Double = 0
    var font = UIFont.preferredFont(forTextStyle: .body)
    var color = UIColor.label
    /// 表示を作り直す番号。続いている入れ替わりを止めるときに増やす。
    var generation = 0
}

/// 変わった数字だけを入れ替えて描く文字。枠はUIKitが決めるので、枠の縦の真ん中に、`alignment`の向きに寄せて描く。
struct NumericTextContent: View {
    let model: NumericTextModel
    let alignment: Alignment

    var body: some View {
        Text(model.text)
            .font(Font(model.font))
            .foregroundStyle(Color(uiColor: model.color))
            .contentTransition(.numericText(value: model.value))
            .id(model.generation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
