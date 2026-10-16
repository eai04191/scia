import UIKit

/// 知らせのチップを、出たままのものを上に1枚、数秒で消えるものをその下に1枚、縦に並べる。1枚だけなら上に詰める。
/// 出方の決まりはdocs/notices.mdの「チップ」と「置き場所」にある。
///
/// 置く側は幅と上端を決める。高さは中身によらず2枚分を取り、チップのないところは触れても下へ通す。
final class NoticeStackView: UIView {
    /// 出入りと並べ直しの時間。
    var animationDuration: TimeInterval = 0.2
    private let spacing: CGFloat = 8
    private var persistentChip: NoticeChip?
    private var transientChip: NoticeChip?
    /// 消している途中のチップ。並べる位置からは外し、消し終えたら取り除く。
    private var removingChips: [NoticeChip] = []
    /// 数秒で消えるチップを消すまでの残りの時間。時計を止めている間だけ使う。
    private var transientRemaining: Duration = .zero
    private var transientDeadline: ContinuousClock.Instant?
    private var hideTask: Task<Void, Never>?
    private var isChromeHidden = false
    /// 高さを測るための、画面に出さないチップ。
    private let sizingChip = NoticeChip()

    var persistentNotice: Notice? { persistentChip?.notice }
    var transientNotice: Notice? { transientChip?.notice }
    /// 上から順に、出しているチップ。消している途中のものは含まない。
    var chips: [NoticeChip] { [persistentChip, transientChip].compactMap(\.self) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 処理中の印は、ほかの印より背が高い。
        sizingChip.apply(Notice(id: "sizing", kind: .progress, title: "あ"))
        // 文字の大きさの設定が変われば、高さを測り直す。
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 出す、消す

    /// 出たままのチップを出すか、中身を替える。nilなら消す。
    func setPersistent(_ notice: Notice?) {
        guard let notice else {
            if let chip = persistentChip {
                persistentChip = nil
                remove(chip)
                relayout()
            }
            return
        }
        if let chip = persistentChip {
            update(chip, with: notice)
        } else {
            let chip = makeChip(notice)
            persistentChip = chip
            appear(chip)
        }
        updateChromeVisibility(animated: true)
    }

    /// 数秒で消えるチップを出す。出していれば差し替え、消えるまでの時計を数え直す。
    /// - Parameter persistentID: 出たままのチップがこのidの知らせなら、それを消してその場所で入れ替える（ダウンロード中から保存しましたへ）。
    func showTransient(_ notice: Notice, duration: TimeInterval, replacingPersistent persistentID: String? = nil) {
        if let persistentID, let chip = persistentChip, chip.notice?.id == persistentID {
            if let old = transientChip {
                remove(old)
            }
            persistentChip = nil
            transientChip = chip
            update(chip, with: notice)
            relayout()
        } else if let chip = transientChip {
            update(chip, with: notice)
        } else {
            let chip = makeChip(notice)
            transientChip = chip
            appear(chip)
        }
        updateChromeVisibility(animated: true)
        hideTask?.cancel()
        transientRemaining = .seconds(duration)
        transientDeadline = nil
        resumeTransientClock()
    }

    /// 画面をタップしてボタン類を隠したか、出し直した。使う人が対処するまで残るもの（出たままの失敗）だけを、場所を空けたまま薄くする。
    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        isChromeHidden = hidden
        updateChromeVisibility(animated: animated)
    }

    private func makeChip(_ notice: Notice) -> NoticeChip {
        let chip = NoticeChip()
        chip.apply(notice)
        chip.announce(changingFrom: nil)
        chip.alpha = 0
        chip.onHoldChange = { [weak self, weak chip] in
            guard let self, let chip else { return }
            self.holdDidChange(chip)
        }
        addSubview(chip)
        return chip
    }

    /// 並びに入れたチップを、その位置で薄い状態から出す。ほかのチップは新しい並びへ動かす。
    private func appear(_ chip: NoticeChip) {
        UIView.performWithoutAnimation {
            chip.frame = frame(for: chip, at: targetOrigins()[ObjectIdentifier(chip)] ?? 0)
            chip.layoutIfNeeded()
        }
        // 視差効果を減らす設定では、大きさを変えずに薄くするだけにする。
        if !UIAccessibility.isReduceMotionEnabled {
            chip.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            chip.alpha = self.targetAlpha(of: chip)
            chip.transform = .identity
        }
        relayout()
    }

    private func update(_ chip: NoticeChip, with notice: Notice) {
        let previous = chip.notice
        defer { chip.announce(changingFrom: previous) }
        // 文言や種類が変わったら、中身だけを薄く入れ替える。進み具合だけなら、そのまま描き直す。
        if chip.notice?.title != notice.title || chip.notice?.kind != notice.kind {
            UIView.transition(with: chip, duration: animationDuration, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
                chip.apply(notice)
            }
        } else {
            chip.apply(notice)
        }
        relayout()
    }

    private func remove(_ chip: NoticeChip) {
        removingChips.append(chip)
        chip.isUserInteractionEnabled = false
        chip.onHoldChange = nil
        UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            chip.alpha = 0
        } completion: { _ in
            // 途中で並べ直しの動きが重なると、完了が先に届くことがあるため、薄くなりきっていなくても取り除く。
            chip.removeFromSuperview()
            self.removingChips.removeAll { $0 === chip }
        }
    }

    private func removeTransient() {
        guard let chip = transientChip else { return }
        transientChip = nil
        transientDeadline = nil
        remove(chip)
        relayout()
    }

    // MARK: 消えるまでの時計

    /// 押せる数秒で消えるチップは、指が触れている間とVoiceOverの読み上げ位置が乗っている間、時計を止める。
    private var isTransientClockPaused: Bool {
        guard let chip = transientChip else { return false }
        return chip.isHeld && chip.notice?.isActionable == true
    }

    private func resumeTransientClock() {
        guard transientChip != nil, transientDeadline == nil, !isTransientClockPaused else { return }
        let remaining = transientRemaining
        transientDeadline = ContinuousClock.now + remaining
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, !Task.isCancelled else { return }
            self.removeTransient()
        }
    }

    private func pauseTransientClock() {
        guard let deadline = transientDeadline else { return }
        hideTask?.cancel()
        hideTask = nil
        transientRemaining = max(.zero, deadline - ContinuousClock.now)
        transientDeadline = nil
    }

    private func holdDidChange(_ chip: NoticeChip) {
        if chip === transientChip {
            if isTransientClockPaused {
                pauseTransientClock()
            } else {
                resumeTransientClock()
            }
        }
        // 触れている間に止めていた並べ直しを、離したら行う。
        if !chip.isHeld {
            relayout()
        }
    }

    // MARK: 並べ方

    /// 上から順に並べたときの、チップごとの上端。
    /// 指が触れているチップは、押そうとしているチップが逃げないよう今の場所から動かさず、ほかのチップはそれと重ならない場所に置く。
    /// 離したら、決まりの並びに戻す。
    private func targetOrigins() -> [ObjectIdentifier: CGFloat] {
        let heldRanges = chips.filter(\.isHeld).map { chip in
            let top = chip.center.y - chip.bounds.height / 2
            return (top: top, bottom: top + chip.bounds.height)
        }
        var origins: [ObjectIdentifier: CGFloat] = [:]
        var y: CGFloat = 0
        for chip in chips {
            if chip.isHeld {
                origins[ObjectIdentifier(chip)] = chip.center.y - chip.bounds.height / 2
                continue
            }
            let height = chipSize(chip).height
            while let held = heldRanges.first(where: { y < $0.bottom + spacing && $0.top < y + height + spacing }) {
                y = held.bottom + spacing
            }
            origins[ObjectIdentifier(chip)] = y
            y += height + spacing
        }
        return origins
    }

    private func chipSize(_ chip: NoticeChip) -> CGSize {
        let size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: min(size.width, bounds.width), height: size.height)
    }

    private func frame(for chip: NoticeChip, at y: CGFloat) -> CGRect {
        let size = chipSize(chip)
        return CGRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
    }

    /// 広げるときは、動きに遅れて文言が切れないよう、すぐ広げる。縮めるときは中身が収まったまま動かせるため、動きに任せる。
    private func placeChips() {
        let origins = targetOrigins()
        for chip in chips {
            let y = origins[ObjectIdentifier(chip)] ?? 0
            let target = frame(for: chip, at: y)
            if target.width > chip.bounds.width || target.height > chip.bounds.height {
                UIView.performWithoutAnimation {
                    chip.bounds.size = CGSize(width: max(target.width, chip.bounds.width), height: max(target.height, chip.bounds.height))
                    chip.layoutIfNeeded()
                }
            }
            if chip.bounds.size != target.size || chip.center != CGPoint(x: target.midX, y: target.midY) {
                chip.bounds.size = target.size
                chip.center = CGPoint(x: target.midX, y: target.midY)
            }
        }
    }

    private func relayout() {
        // 視差効果を減らす設定では、詰め直しを動かさずに置き直す。
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            placeChips()
            return
        }
        UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.placeChips()
            self.layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeChips()
    }

    /// 中身によって高さを変えると、置く側の並べ直しがチップの動きの途中に入り、チップが上下に揺れるため、いつも2枚分の高さを取る。
    override var intrinsicContentSize: CGSize {
        let chipHeight = sizingChip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        return CGSize(width: UIView.noIntrinsicMetric, height: chipHeight * 2 + spacing)
    }

    // MARK: ボタン類を隠したとき

    private func isHiddenWithChrome(_ chip: NoticeChip) -> Bool {
        isChromeHidden && chip === persistentChip && chip.notice?.kind == .failure
    }

    private func targetAlpha(of chip: NoticeChip) -> CGFloat {
        isHiddenWithChrome(chip) ? 0 : 1
    }

    private func updateChromeVisibility(animated: Bool) {
        let apply = {
            for chip in self.chips {
                chip.alpha = self.targetAlpha(of: chip)
            }
        }
        for chip in chips {
            chip.isUserInteractionEnabled = chip.notice?.isActionable == true && !isHiddenWithChrome(chip)
        }
        if animated {
            UIView.animate(withDuration: animationDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: 触れたもの

    /// チップの上だけを受け、ほかは下の画面へ通す。チップは44pt四方まで外側も押せるため、並べた範囲の外でも受ける。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        for chip in chips.reversed() where chip.isUserInteractionEnabled {
            if chip.point(inside: convert(point, to: chip), with: event) {
                return chip
            }
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitTest(point, with: event) != nil
    }
}
