import SciaCore
import SwiftUI
import UIKit

/// リアクションを、絵文字と数のボタンで並べ、入りきらなければ折り返す。最後に、絵文字のシートを開く「＋」を置く。サーバーのお知らせと投稿で使う。
final class ReactionChipsView: UIView {
    struct Reaction {
        var name: String
        /// 絵文字を描いた文字。カスタム絵文字は画像で描く。
        var emoji: NSAttributedString
        var count: Int
        var isMine: Bool
        /// 読み上げで絵文字の代わりに読む文字。カスタム絵文字はショートコード。
        var spokenName: String
    }

    /// ボタンの文字と大きさ。投稿では「投稿の見た目」の値で決め、サーバーのお知らせでは`standard`を使う。
    struct Style: Equatable {
        /// 絵文字と数の文字。数は、この文字で数字の幅を揃えて描く。
        var font: UIFont
        /// ボタンどうしのあいだ。折り返した行のあいだも同じにする。
        var spacing: CGFloat
        /// ボタンの文字の上下と左右の余白。
        var padding: NSDirectionalEdgeInsets

        static var standard: Style {
            Style(font: .preferredFont(forTextStyle: .subheadline), spacing: 6, padding: NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        }
    }

    /// リアクションを押したときに、その絵文字の名前を渡して呼ぶ。
    var onToggle: ((String) -> Void)?
    /// 「＋」を押したときに呼ぶ。
    var onAdd: (() -> Void)?
    /// リアクションのボタンのタップと長押しの対象。絵文字の名前を渡して受け取る。nilなら、タップで`onToggle`を呼び、長押しのメニューは出さない（サーバーのお知らせ）。
    /// 決まりはdocs/emoji-reaction.mdの「リアクションのボタンのメニュー」にある。
    var target: ((String) -> (any ObjectActionTarget)?)?
    /// 動くカスタム絵文字を動かすときのストア。nilなら動かさない。
    var animatedEmojis: EmojiImageStore<UIImage>?
    /// まだ幅が決まっていないときに、高さを測る幅。一覧の行は、幅が決まる前に高さを測ることがあり、0の幅で測るとボタンが1つずつ折り返して高く測られるため。
    var widthHint: CGFloat?
    /// 幅が決まって、測った高さが変わったときに呼ぶ。置いている一覧の行に高さを測り直させる。
    var onHeightChange: (() -> Void)?
    /// 付いた、なくなった、数が変わったときに動かす時間。0なら切り替える。投稿では、チューニングの値を入れる。
    var transitionDuration: TimeInterval = 0
    /// 「＋」を出すか。
    var showsAddButton = true {
        didSet {
            guard showsAddButton != oldValue else { return }
            arrangeButtons()
        }
    }
    private var reactionOrder: [String] = []
    private(set) var style = Style.standard

    /// 並べている順のボタン。最後は「＋」。
    private var buttons: [UIControl] = []
    /// 絵文字の名前ごとのボタン。描き直しでも同じリアクションのボタンは使い回し、押している途中のボタンを作り替えてタップを取り消さない。
    private var reactionButtons: [String: ReactionChipButton] = [:]
    private lazy var addButton = makeAddButton()
    /// 最後に知らせた高さ。置かれた幅で並べた高さと違えば、測り直させる。
    private var reportedHeight: CGFloat?
    /// 次に並べるときに、前の位置から動かすか。動かす描き直しの`apply`で立て、並べたら下ろす。
    /// 動きはどれも`apply`では始めず、並べるときに始める。一覧は行の中身を動きを止めた描き直し（`apply(_:animatingDifferences: false)`）の中で当てるため、その中で始めた`UIView.animate`は効かない。
    private var animatesNextLayout = false
    /// 次に並べるときに、その場で浮かび上がらせるボタン。新しく付いたリアクションと、列ごと出てきたときの「＋」。
    private var enteringButtons: Set<ObjectIdentifier> = []
    /// 次に並べるときに、縮めながら薄くして外すボタン。
    private var leavingButtons: [ReactionChipButton] = []
    /// 消えている途中から戻すボタン。浮かび上がらせるときに、小さく薄い状態に戻さず、今の状態から動かす。
    private var revivingButtons: Set<ObjectIdentifier> = []
    /// 次に並べるときに、浮かび上がるボタンを、ほかのボタンが場所を空けてから浮かび上がらせるか。すでにボタンのある列に付いたときに立てる。
    private var delaysEntering = false
    /// 消えている途中のボタンを、絵文字の名前ごとに覚える。消え終える前に同じ絵文字がまた付いたら、新しいボタンを作らずに、このボタンを今の状態から戻す。
    /// 別のボタンを作ると、同じリアクションが消えかけの位置と新しい位置に同時に見えるため。
    private var leavingByName: [String: ReactionChipButton] = [:]

    /// - Parameter animated: 前の中身から動かして替える。付いたボタンはその場で浮かび上がり、なくなったボタンは縮みながら消え、残るボタンは新しい位置へ動き、数は入れ替わる（docs/emoji-reaction.mdの「動き」）。
    ///   同じ投稿の描き直しで、画面に出ているときだけ渡す。視差効果を減らす設定と、時間が0のときは動かさない。
    func apply(_ reactions: [Reaction], style: Style = .standard, animated: Bool = false) {
        let animates = animated && transitionDuration > 0 && window != nil && !UIAccessibility.isReduceMotionEnabled
        if style != self.style {
            self.style = style
            applyStyle(to: addButton)
            addButton.label.attributedText = addSymbol()
        }
        let wasEmpty = reactionOrder.isEmpty
        var used: [String: ReactionChipButton] = [:]
        for reaction in reactions {
            var existing = reactionButtons[reaction.name]
            if existing == nil, let leaving = leavingByName.removeValue(forKey: reaction.name) {
                // 消えている途中のボタンを戻す。並べるときに、今の大きさと濃さから元へ戻す。
                leavingButtons.removeAll { $0 === leaving }
                leaving.isUserInteractionEnabled = true
                leaving.isAccessibilityElement = true
                enteringButtons.insert(ObjectIdentifier(leaving))
                revivingButtons.insert(ObjectIdentifier(leaving))
                existing = leaving
            }
            let button = existing ?? makeButton(name: reaction.name)
            configure(button, with: reaction, animated: animates && existing != nil)
            if animates, existing == nil {
                enteringButtons.insert(ObjectIdentifier(button))
            }
            used[reaction.name] = button
        }
        for (name, button) in reactionButtons where used[name] == nil {
            if animates {
                button.isUserInteractionEnabled = false
                button.isAccessibilityElement = false
                leavingButtons.append(button)
                leavingByName[name] = button
            } else {
                button.removeFromSuperview()
            }
        }
        // 列ごと出てきたときは、「＋」もリアクションと一緒に浮かび上がらせる。
        if animates, wasEmpty, !reactions.isEmpty, showsAddButton {
            enteringButtons.insert(ObjectIdentifier(addButton))
        }
        reactionButtons = used
        reactionOrder = reactions.map(\.name)
        animatesNextLayout = animates
        delaysEntering = animates && !wasEmpty
        arrangeButtons()
    }

    /// 続いている動きと、まだ始めていない動きをやめ、今の中身のまま止める。行が別の投稿に使い回されたときに呼ぶ。
    /// やめないと、前の投稿の数の入れ替わりや消えかけのボタンが、新しい投稿の上で続くため。
    func cancelTransitions() {
        animatesNextLayout = false
        delaysEntering = false
        enteringButtons.removeAll()
        revivingButtons.removeAll()
        for button in leavingButtons + Array(leavingByName.values) {
            button.removeFromSuperview()
        }
        leavingButtons.removeAll()
        leavingByName.removeAll()
        for button in buttons {
            button.layer.removeAllAnimations()
            button.alpha = 1
            button.transform = .identity
            (button as? ReactionChipButton)?.cancelTransitions()
        }
        setNeedsLayout()
    }

    /// なくなったリアクションのボタンを、その場で縮めながら薄くして外す。並びからは先に外し、残るボタンはその空きへ動く。
    /// 残るボタンが空きへ動くより早く消し終える。同じ長さにすると、縮みきる前の消えるボタンに、隣のボタンが重なって見えるため（録画で確かめた）。
    private func leave(_ button: ReactionChipButton) {
        UIView.animate(springDuration: transitionDuration * Self.leavingDurationRatio, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            button.alpha = 0
            button.transform = CGAffineTransform(scaleX: Self.enteringScale, y: Self.enteringScale)
        } completion: { [weak self] _ in
            // 消え終える前に戻したボタンは外さない。
            guard let self, leavingByName.values.contains(where: { $0 === button }) else { return }
            leavingByName = leavingByName.filter { $0.value !== button }
            button.removeFromSuperview()
        }
    }

    /// 消えるボタンの動きの時間の、ほかの動きの時間に対する割合。
    private static let leavingDurationRatio = 0.5

    /// すでにボタンのある列で、浮かび上がるボタンを待たせる時間の、ほかの動きの時間に対する割合。
    /// 新しいボタンは、そこにいた「＋」などが動いて空ける場所に浮かび上がる。同時に始めると、動き出したばかりのボタンに重なって見えるため（録画で確かめた）。
    /// 半分の時間で、動くボタンは道のりの8割ほどを進み、縮めてある新しいボタンの範囲から出る。
    private static let enteringDelayRatio = 0.5

    /// 出入りするボタンの、見えないときの大きさの割合。何もないところから現れず、その場で膨らんで見えるよう、0にはしない。
    private static let enteringScale: CGFloat = 0.5

    private func arrangeButtons() {
        buttons = reactionOrder.compactMap { reactionButtons[$0] } + (showsAddButton ? [addButton] : [])
        if !showsAddButton {
            addButton.removeFromSuperview()
        }
        for button in buttons where button.superview !== self {
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let height = layout(width: measuringWidth).height
        reportedHeight = height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    private var measuringWidth: CGFloat {
        bounds.width > 0 ? bounds.width : widthHint ?? bounds.width
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = layout(width: bounds.width).frames
        let animates = animatesNextLayout
        animatesNextLayout = false
        let enteringDelay = delaysEntering ? transitionDuration * Self.enteringDelayRatio : 0
        delaysEntering = false
        for button in leavingButtons {
            leave(button)
        }
        leavingButtons.removeAll()
        for (button, frame) in zip(buttons, frames) {
            // 浮かび上がる途中のボタンは縮めてあるので、枠ではなく中心と大きさで置く。
            let place = {
                button.bounds.size = frame.size
                button.center = CGPoint(x: frame.midX, y: frame.midY)
            }
            if enteringButtons.remove(ObjectIdentifier(button)) != nil {
                var delay = 0.0
                if revivingButtons.remove(ObjectIdentifier(button)) != nil {
                    // 消えかけのボタンは、縮んだまま新しい位置へ動かしながら戻す。
                    UIView.animate(springDuration: transitionDuration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                        place()
                        button.layoutIfNeeded()
                        button.alpha = 1
                        button.transform = .identity
                    }
                } else {
                    UIView.performWithoutAnimation {
                        place()
                        button.layoutIfNeeded()
                        button.alpha = 0
                        button.transform = CGAffineTransform(scaleX: Self.enteringScale, y: Self.enteringScale)
                    }
                    delay = enteringDelay
                }
                UIView.animate(springDuration: transitionDuration, bounce: 0, initialSpringVelocity: 0, delay: delay, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    button.alpha = 1
                    button.transform = .identity
                }
            } else if animates {
                UIView.animate(springDuration: transitionDuration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    place()
                    button.layoutIfNeeded()
                }
            } else {
                place()
            }
            (button as? ReactionChipButton)?.startPendingAnimations()
        }
        // 測ったときの幅と違う幅に置かれて高さが変わったら、測り直させる。
        if bounds.width > 0, layout(width: bounds.width).height != reportedHeight {
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }

    /// 左から詰めて並べ、幅を超えたら次の行へ送る。
    private func layout(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let fitted = CGSize(width: min(size.width, max(width, 1)), height: size.height)
            if x > 0, x + fitted.width > width {
                x = 0
                y += rowHeight + style.spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: fitted))
            x += fitted.width + style.spacing
            rowHeight = max(rowHeight, fitted.height)
        }
        return (frames, y + rowHeight)
    }

    /// 「投稿の見た目」のプレビューで、ボタンの場所を示すための枠。`space`の座標で、並べた順に返す。
    func chipPreviewFrames(in space: UIView) -> [CGRect] {
        buttons.map { button in
            let size = button.bounds.size
            let frame = CGRect(x: button.center.x - size.width / 2, y: button.center.y - size.height / 2, width: size.width, height: size.height)
            return convert(frame, to: space)
        }
    }

    private func applyStyle(to button: ReactionChipButton) {
        button.label.font = style.font
        button.countFont = style.font.withMonospacedDigits
        button.padding = style.padding
        button.setNeedsLayout()
    }

    private func makeButton(name: String) -> ReactionChipButton {
        let button = ReactionChipButton()
        applyStyle(to: button)
        button.addAction(UIAction { [weak self, weak button] _ in
            // 対象があれば、タップに割り当てた操作を行う。なければ付け外しする。
            if let interaction = button?.interaction, interaction.target != nil {
                interaction.handleTap()
            } else {
                self?.onToggle?(name)
            }
        }, for: .touchUpInside)
        return button
    }

    private func configure(_ button: ReactionChipButton, with reaction: Reaction, animated: Bool) {
        applyStyle(to: button)
        if let target = target?(reaction.name) {
            button.objectInteraction().target = target
        } else {
            button.interaction?.target = nil
        }
        button.label.emojiImages = animatedEmojis
        button.label.attributedText = reaction.emoji
        button.setCount(reaction.count, isMine: reaction.isMine, animation: animated ? transitionDuration : nil)
        button.accessibilityLabel = "\(reaction.spokenName) \(reaction.count.formatted())件"
        button.accessibilityValue = reaction.isMine ? "リアクション済み" : nil
        button.accessibilityTraits = reaction.isMine ? [.button, .selected] : .button
        button.setNeedsLayout()
    }

    private func makeAddButton() -> ReactionChipButton {
        let button = ReactionChipButton()
        applyStyle(to: button)
        button.label.attributedText = addSymbol()
        button.label.textColor = .secondaryLabel
        button.accessibilityLabel = "リアクションを追加"
        button.accessibilityTraits = .button
        button.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        return button
    }

    /// 「＋」の記号。絵文字と数の文字の大きさで描く。
    private func addSymbol() -> NSAttributedString {
        let configuration = UIImage.SymbolConfiguration(font: style.font)
        return NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "plus", withConfiguration: configuration) ?? UIImage()))
    }
}

/// リアクションのボタン。カスタム絵文字を本文と同じく動かすため、`UIButton`ではなく`EmojiLabel`を載せる。自分がしたものはアプリの色で塗る。
/// 数は絵文字と別に、SwiftUIの`Text`で描き、数が変わったときに、変わった桁だけを入れ替える（`numericText`）。「＋」は数を出さない。
final class ReactionChipButton: UIControl {
    let label = EmojiLabel()
    /// タップと長押しの対象を付けたもの。対象を渡されたときに作る。長押しでは、ボタンをカプセルの形のまま持ち上げる。
    private(set) var interaction: ObjectInteraction?
    private let countModel = ReactionCountModel()
    private lazy var countHosting = UIHostingController(rootView: ReactionCountView(model: countModel))
    /// 数の文字。数字の幅を揃えたもの。
    var countFont: UIFont = .monospacedDigitFont(forTextStyle: .subheadline) {
        didSet {
            guard countFont != oldValue else { return }
            withoutAnimation { countModel.font = countFont }
            setNeedsLayout()
        }
    }
    private(set) var count: Int?
    /// 前に並べたときの、数の枠の幅。
    private var lastCountFrameWidth: CGFloat?
    /// 数を入れ替えている間に保つ、数の枠の幅。入れ替わる前の数の枠の幅で、入れ替わり終えたらnilに戻す。
    private var transitionCountFrameWidth: CGFloat?
    /// 最後に数を替えたときの動きの時間。動かさずに替えたらnil。テストで、数を動かして替えたかを確かめるために使う。
    private(set) var lastCountTransition: TimeInterval?
    /// SwiftUIの数の表示を作り直した回数。テストで、使い回したときに作り直したかを確かめるために使う。
    var countGeneration: Int { countModel.generation }
    /// 数を描く枠。テストで、ボタンの中に収まっているかを確かめるために使う。
    var countFrame: CGRect { countHosting.view.frame }
    var padding = ReactionChipsView.Style.standard.padding {
        didSet { setNeedsLayout() }
    }
    /// 押せる範囲の高さ。見た目は小さくても、押せる範囲は44pt取る。
    private static let minimumHitHeight: CGFloat = 44

    private(set) var isMine = false

    func objectInteraction() -> ObjectInteraction {
        if let interaction { return interaction }
        let made = ObjectInteraction(on: self, tapsSelf: false, lift: .shape)
        interaction = made
        return made
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        layer.cornerCurve = .continuous
        label.numberOfLines = 1
        label.isUserInteractionEnabled = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        countModel.font = countFont
        let countView: UIView = countHosting.view
        countView.backgroundColor = .clear
        countView.isUserInteractionEnabled = false
        countView.accessibilityElementsHidden = true
        countView.isHidden = true
        // 数の幅はUIKitの並べ方で決め、SwiftUIには、その枠の左端に寄せて描かせる。
        countHosting.sizingOptions = []
        countHosting.safeAreaRegions = []
        addSubview(label)
        addSubview(countView)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 高さは中身ではなく文字の行の高さで決める。カスタム絵文字の画像はUnicodeの絵文字より行を少し高くするため、中身で決めると並んだボタンの高さが揃わない。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let side = sidePadding(within: size.width)
        let contentWidth = contentSizes(within: size.width - side.leading - side.trailing).total
        let lineHeight = ceil(label.font.lineHeight)
        return CGSize(width: max(ceil(contentWidth) + side.leading + side.trailing, 44), height: lineHeight + padding.top + padding.bottom)
    }

    /// 絵文字と数を並べる幅。数のあいだは、これまで空白1文字で空けていたのと同じ幅にする。
    /// 数の幅は、SwiftUIに測らせず、同じ文字でUIKitで測る。並べる時点では、SwiftUIの数はまだ前の数のことがあるため。
    private func contentSizes(within width: CGFloat) -> (emoji: CGSize, count: CGSize, gap: CGFloat, total: CGFloat) {
        guard let count else {
            let emoji = label.sizeThatFits(CGSize(width: max(width, 0), height: .greatestFiniteMagnitude))
            return (emoji, .zero, 0, emoji.width)
        }
        let measured = (count.formatted() as NSString).size(withAttributes: [.font: countFont])
        // 数も、ボタンに入る幅までにする。狭い列で桁の多い数を出すと、ボタンの右端からはみ出すため。
        let countSize = CGSize(width: min(ceil(measured.width), max(width, 0)), height: ceil(countFont.lineHeight))
        let gap = min(ceil((" " as NSString).size(withAttributes: [.font: countFont]).width), max(width - countSize.width, 0))
        let emoji = label.sizeThatFits(CGSize(width: max(width - countSize.width - gap, 0), height: .greatestFiniteMagnitude))
        return (emoji, countSize, gap, emoji.width + gap + countSize.width)
    }

    /// 数と、自分がしたかを当てる。`animation`があれば、次に並べるときに（`startPendingAnimations`）、その時間で数を入れ替え、色を移す。
    /// 数は、変わった桁だけが入れ替わり、増えたら上へ、減ったら下へ動く（`numericText(value:)`）。
    func setCount(_ newCount: Int, isMine newIsMine: Bool, animation duration: TimeInterval?) {
        let oldCount = count
        let changesColor = newIsMine != isMine
        count = newCount
        isMine = newIsMine
        countHosting.view.isHidden = false
        if let duration, oldCount != nil, oldCount != newCount || changesColor {
            pendingCount = (newCount, newIsMine, duration)
            transitionCountFrameWidth = max(transitionCountFrameWidth ?? 0, lastCountFrameWidth ?? 0)
        } else {
            transitionCountFrameWidth = nil
            pendingCount = nil
            lastCountTransition = nil
            withoutAnimation {
                countModel.count = newCount
                countModel.isMine = newIsMine
            }
        }
        if let duration, changesColor {
            pendingColorChange = (layer.presentation()?.borderWidth ?? layer.borderWidth, duration)
        } else {
            pendingColorChange = nil
            updateColors()
        }
    }

    /// 次に並べるときに替える数と、自分がしたか、時間。
    private var pendingCount: (count: Int, isMine: Bool, duration: TimeInterval)?
    /// 次に並べるときに移す色。前の枠の太さと、時間。
    private var pendingColorChange: (oldBorderWidth: CGFloat, duration: TimeInterval)?

    /// 数の入れ替わりと色の移りをやめ、今の数と色のまま止める。
    func cancelTransitions() {
        pendingCount = nil
        pendingColorChange = nil
        lastCountTransition = nil
        transitionCountFrameWidth = nil
        // 同じ値を入れ直すだけでは、SwiftUIで続いている入れ替わりは止まらない。表示を作り直して止める。
        withoutAnimation {
            countModel.generation += 1
            if let count {
                countModel.count = count
                countModel.isMine = isMine
            }
        }
        layer.removeAnimation(forKey: "reactionBorder")
        updateColors()
    }

    /// `setCount`で決めた動きを始める。並べ終えてから呼ぶ。
    /// 一覧は行の中身を動きを止めた描き直しの中で当てるため、`setCount`の中では始めない。
    func startPendingAnimations() {
        if let change = pendingColorChange {
            pendingColorChange = nil
            animateColors(from: change.oldBorderWidth, duration: change.duration)
        }
        guard let pending = pendingCount else { return }
        pendingCount = nil
        lastCountTransition = pending.duration
        let generation = countModel.generation
        withAnimation(.smooth(duration: pending.duration), completionCriteria: .removed) {
            countModel.count = pending.count
            countModel.isMine = pending.isMine
        } completion: { [weak self] in
            // 入れ替わり終えたら、新しい数の幅に戻す。後に続く入れ替わりや作り直しがあれば、そちらに任せる。
            guard let self, countModel.generation == generation, pendingCount == nil else { return }
            transitionCountFrameWidth = nil
            setNeedsLayout()
        }
    }

    /// 動かさずにSwiftUIの数を替える。
    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    /// 幅`width`に置くときの左右の余白。余白で幅の半分より多くを取らないよう、左右の比を保って縮める。
    /// 「投稿の見た目」で余白を大きくし、列が狭いとき（アイコンを大きくして下を空けるときなど）に、文字の幅が負にならないようにするため。
    func sidePadding(within width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let total = padding.leading + padding.trailing
        let limit = max(width, 0) / 2
        guard total > limit, total > 0 else { return (padding.leading, padding.trailing) }
        let scale = limit / total
        return (padding.leading * scale, padding.trailing * scale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 中身の高さのまま縦の真ん中に置く。行より高い中身も、切らずにはみ出させる。
        let side = sidePadding(within: bounds.width)
        let width = bounds.width - side.leading - side.trailing
        let sizes = contentSizes(within: width)
        guard count != nil else {
            let height = ceil(sizes.emoji.height)
            label.frame = CGRect(x: side.leading, y: (bounds.height - height) / 2, width: width, height: height)
            label.textAlignment = .center
            return
        }
        let start = side.leading + max((width - sizes.total) / 2, 0)
        let emojiWidth = min(ceil(sizes.emoji.width), max(width - sizes.gap - sizes.count.width, 0))
        let emojiHeight = ceil(sizes.emoji.height)
        label.textAlignment = .natural
        label.frame = CGRect(x: start, y: (bounds.height - emojiHeight) / 2, width: emojiWidth, height: emojiHeight)
        // 数の枠は左端に寄せて描かせ、入れ替わっている間は、入れ替わる前の枠の幅より狭めない。
        // ボタンの幅は先に新しい幅になるので、新しい数の幅にすると、数が減って幅が狭まるときに、入れ替わる途中の前の数が切り詰められるため（録画で確かめた）。
        // 入れ替わっていないときは今の幅に収める。列が狭まったときに、前の広い枠のまま数をボタンからはみ出させないため。
        let countX = start + emojiWidth + sizes.gap
        let available = max(bounds.width - countX - side.trailing, ceil(sizes.count.width))
        let countWidth = max(available, transitionCountFrameWidth ?? 0)
        lastCountFrameWidth = countWidth
        countHosting.view.frame = CGRect(x: countX, y: 0, width: countWidth, height: bounds.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extra = max(0, Self.minimumHitHeight - bounds.height) / 2
        return bounds.insetBy(dx: 0, dy: -extra).contains(point)
    }

    // 枠の色はCGColorで、ティントカラーが変わっても描き直されないため、変わったら当て直す。
    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    private func updateColors() {
        backgroundColor = isMine ? tintColor.withAlphaComponent(0.18) : .secondarySystemFill
        layer.borderWidth = isMine ? 1 : 0
        layer.borderColor = tintColor.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
    }

    /// 自分がしたかが変わったときに、塗りと枠を前の色から移す。枠の太さは層の値なので、`UIView.animate`では動かず、層の動きで移す。
    private func animateColors(from oldWidth: CGFloat, duration: TimeInterval) {
        UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.backgroundColor = self.isMine ? self.tintColor.withAlphaComponent(0.18) : .secondarySystemFill
        }
        layer.borderColor = tintColor.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = isMine ? 1 : 0
        let border = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        border.keyPath = "borderWidth"
        border.fromValue = oldWidth
        border.toValue = layer.borderWidth
        border.duration = border.settlingDuration
        layer.add(border, forKey: "reactionBorder")
    }
}

/// リアクションのボタンの数。UIKitのボタンが当て、SwiftUIの`ReactionCountView`が描く。
@MainActor
@Observable
final class ReactionCountModel {
    var count = 0
    var isMine = false
    /// 表示を作り直す番号。行が別の投稿に使い回されたときに増やし、続いている入れ替わりを止める。
    var generation = 0
    var font: UIFont = .monospacedDigitFont(forTextStyle: .subheadline)
}

/// リアクションのボタンの数。変わった桁だけを入れ替える（`numericText(value:)`）。自分がしたものはアプリの色で描く。
/// 枠の左端に寄せ、縦の真ん中に置く。枠はUIKitが列に収めて決めるので、狭い列で入りきらなければ1行で切り詰める。
struct ReactionCountView: View {
    let model: ReactionCountModel

    var body: some View {
        Text(model.count.formatted())
            .font(Font(model.font))
            .foregroundStyle(model.isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .contentTransition(.numericText(value: Double(model.count)))
            .lineLimit(1)
            .id(model.generation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
