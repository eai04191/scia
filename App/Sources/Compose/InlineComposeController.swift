import Observation
import os
import SciaCore
import UIKit

/// タブバーの上に常に出しておく投稿欄。タイムラインを見たまま短い投稿や返信を書けるようにする。
///
/// 書いていないときは、一覧の閲覧を邪魔しないよう、タブバーのすぐ上に細いカプセルで下書きの1行だけを見せる。
/// 書くときは同じバーが広がり、キーボードの上へ上がる。タブバーのアクセサリー（`bottomAccessory`）は高さをシステムが決めていて細くできず、
/// キーボードにも隠れるため使わない。
@MainActor
final class InlineComposeController: NSObject {
    let model: ComposeModel
    /// 編集を始めるときに呼ぶ。既定の公開範囲などをまだ読めていなければ読む。
    var onBeginEditing: () -> Void = {}
    /// 全画面の投稿画面に広げる。
    var onExpand: () -> Void = {}
    /// 返信先の札を押したときに呼ぶ。返信先の投稿を見せる。
    var onShowReplyTarget: (Status) -> Void = { _ in }
    /// 投稿できたあとに呼ぶ。
    var onPosted: () -> Void = {}
    /// 画面の下端から、投稿欄（書いているときはキーボードも）が覆っている高さが変わったときに呼ぶ。
    var onObscuredHeightChange: (CGFloat) -> Void = { _ in }

    private weak var host: UIViewController?
    private let tuning: TuningStore
    private let logger = SciaLog.logger(category: "compose")
    /// 書いていないときに見せる、下書きの1行。押すと書き始める。
    private let restRow = UIControl()
    private let restLabel = UILabel()
    /// 書き始めて行を隠すと、スタックビューが高さ0の制約を付ける。それと競合しないよう、必須より1つ下げる。
    private lazy var restRowHeight: NSLayoutConstraint = {
        let constraint = restRow.heightAnchor.constraint(equalToConstant: 0)
        constraint.priority = .required - 1
        return constraint
    }()
    private let bar = ComposeBarView(effect: InlineComposeController.interactiveGlass())
    /// 背景の付いた札にする。背景のない文字だけのボタンは、ガラスの上で単色に描かれることがあり、色合いの青が消えた。
    private lazy var replyButton = UIButton(configuration: .tinted(), primaryAction: UIAction { [weak self] _ in
        guard let target = self?.model.replyTo else { return }
        self?.onShowReplyTarget(target)
    })
    private lazy var replyRow = makeReplyRow()
    private let textView = ComposeTextView()
    private let placeholderLabel = UILabel()
    /// 書き終えて入力欄を隠すと、スタックビューが高さ0の制約を付ける。それと競合しないよう、必須より1つ下げる。
    private lazy var textHeightLimit: NSLayoutConstraint = {
        let constraint = textView.heightAnchor.constraint(equalToConstant: maxTextHeight)
        constraint.priority = .required - 1
        return constraint
    }()
    private let visibilityButton = UIButton(configuration: .plain())
    private let remainingLabel = UILabel()
    private lazy var sendButton = UIButton(configuration: .filled(), primaryAction: UIAction { [weak self] _ in self?.submit() })
    private var isPresentingError = false
    /// 入力バーと、その下のタブバーやキーボードとの間の余白。
    private let barSpacing: CGFloat = 8
    private var obscuredHeight: CGFloat = 0
    /// 書いていないときの、中身の上下の余白。
    private let restInset: CGFloat = 4
    /// 書いている。バーを広げて、入力欄とボタンを出している。
    private var isEditing = false
    /// 中身の上下の余白。書いていないときは細くするため詰める。
    private lazy var stackTop = stack.topAnchor.constraint(equalTo: dragArea.contentLayoutGuide.topAnchor)
    private lazy var stackBottom = stack.bottomAnchor.constraint(equalTo: dragArea.contentLayoutGuide.bottomAnchor)
    private let stack = UIStackView()
    private let tools = UIStackView()
    /// 入力バーの中身を載せるスクロールビュー。バーを下へ引くと、キーボードが指に付いて下がる。
    private let dragArea = KeyboardDragArea()

    /// 触れるとわずかに膨らんで明るくなるガラス。押せるものだと指に伝える。
    private static func interactiveGlass() -> UIGlassEffect {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        return glass
    }

    /// 入力欄がこれより高くなったら、伸ばさずに中でスクロールする。
    private var maxTextHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight * 5 + textView.textContainerInset.top + textView.textContainerInset.bottom
    }

    init(model: ComposeModel, tuning: TuningStore = AppDependencies.tuning) {
        self.model = model
        self.tuning = tuning
        super.init()
        model.onPosted = { [weak self] in
            self?.textView.resignFirstResponder()
            self?.onPosted()
        }
    }

    /// 投稿欄を`host`の画面に置く。書いていないときはタブバーのすぐ上に、書いているときはキーボードのすぐ上に来る。
    ///
    /// 下端は「タブバーの上」と「キーボードの上」のうち高い方に揃える。キーボードを指で引き下ろしている間も、
    /// キーボードに付いて下がり、タブバーの上で止まる。
    func install(in host: UITabBarController) {
        self.host = host
        configureBar()
        host.view.addSubview(bar)
        let restingBottom = bar.bottomAnchor.constraint(equalTo: host.contentLayoutGuide.bottomAnchor, constant: -barSpacing)
        restingBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: host.contentLayoutGuide.bottomAnchor, constant: -barSpacing),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: host.view.keyboardLayoutGuide.topAnchor, constant: -barSpacing),
            restingBottom,
        ])
        bar.onFrameChange = { [weak self] in self?.reportObscuredHeight() }
        AppDependencies.stateDumps.register("composer", owner: self) { $0.stateDump() }
        applyEditingLayout()
        observeModel()
        observeTuning()
    }

    /// バーを広げて、キーボードを出す。
    func beginEditing() {
        onBeginEditing()
        setEditing(true)
        // 書いていない間に下書きが変わっていても、出す前に高さを合わせる。
        bar.layoutIfNeeded()
        textDidChange()
        textView.becomeFirstResponder()
    }

    /// キーボードを閉じて、バーを細いカプセルに戻す。
    func endEditing() {
        textView.resignFirstResponder()
    }

    /// 違和感レポートに残す状態。行が重なっていれば、どの行かも書く。
    func stateDump() -> String {
        """
        editing: \(isEditing) firstResponder: \(textView.isFirstResponder) replyTo: \(model.replyTo?.id ?? "nil")
        bar.frame: \(bar.frame)
        rows: \(rowStates.map { "\($0.name) hidden=\($0.view.isHidden) frame=\($0.view.frame)" }.joined(separator: ", "))
        overlaps: \(overlappingRows.isEmpty ? "none" : overlappingRows.joined(separator: ", "))
        replyChip: title=\(replyButton.configuration?.title ?? "nil") frame=\(replyButton.frame) label=\(replyButton.titleLabel.map { "text=\($0.text ?? "nil") frame=\($0.frame) alpha=\($0.alpha) hidden=\($0.isHidden)" } ?? "nil")
        """
    }

    private var rowStates: [(name: String, view: UIView)] {
        [("rest", restRow), ("reply", replyRow), ("text", textView), ("tools", tools)]
    }

    /// 表示しているのに高さを確保できていない行と、縦に重なっている行の組み。
    /// スタックビューが行を隠したものとして扱うと、行は見えたまま高さが0になり、中身が下の行に重なって描かれる。
    var overlappingRows: [String] {
        let visible = rowStates.filter { !$0.view.isHidden && $0.view.alpha > 0 }
        let collapsed = visible.filter { $0.view.frame.height < 1 }.map { "\($0.name)(高さ0)" }
        let overlapped = zip(visible, visible.dropFirst()).compactMap { upper, lower in
            upper.view.frame.maxY > lower.view.frame.minY + 0.5 ? "\(upper.name)/\(lower.name)" : nil
        }
        return collapsed + overlapped
    }

    /// 返信先を付けて書き始める。
    func reply(to status: Status) {
        model.setReplyTarget(status)
        // モデルの変更が画面に届くのは少しあとなので、札の行を出す前に、札の文字をここで入れておく。
        update()
        beginEditing()
    }

    /// 書きかけの下書きのまま、全画面の投稿画面に広げる。
    func expand() {
        textView.resignFirstResponder()
        onExpand()
    }

    private func submit() {
        Task { await model.submit() }
    }

    /// バーの上端から画面の下端までを覆っている。書いていればキーボードも含む。バーが動くたびに測り直す。
    private func reportObscuredHeight() {
        guard let host else { return }
        let height = max(0, host.view.bounds.maxY - bar.frame.minY + barSpacing)
        guard height != obscuredHeight else { return }
        obscuredHeight = height
        onObscuredHeightChange(height)
    }

    /// 書き始めと書き終わりで、バーの中身を入れ替える。高さの変化はキーボードの動きと並べて動かす。
    private func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeMorphDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.applyEditingLayout()
            self.host?.view.layoutIfNeeded()
        } completion: { _ in
            self.logOverlappingRows(after: editing ? "begin editing" : "end editing")
        }
    }

    private func applyEditingLayout() {
        setRowHidden(restRow, isEditing)
        restRow.alpha = isEditing ? 0 : 1
        for view in [textView, tools] {
            setRowHidden(view, !isEditing)
            view.alpha = isEditing ? 1 : 0
        }
        let showsReply = isEditing && model.replyTo != nil
        setRowHidden(replyRow, !showsReply)
        replyRow.alpha = showsReply ? 1 : 0
        stackTop.constant = isEditing ? 10 : restInset
        stackBottom.constant = isEditing ? -10 : -restInset
    }

    /// スタックビューの行は、値が変わるときだけ隠したり出したりする。同じ値を、特にアニメーションの途中に代入し直すと、
    /// スタックビューが行を隠したものとして高さ0で並べたまま、行は見えている状態になり、返信先の札が入力欄に重なって描かれた。
    private func setRowHidden(_ view: UIView, _ hidden: Bool) {
        guard view.isHidden != hidden else { return }
        view.isHidden = hidden
    }

    /// 行が重なっていたら、違和感レポートで追えるようログに残す。
    /// 画面に置いた直後は、まだ大きさが決まっておらず行の高さがどれも0なので見ない。
    private func logOverlappingRows(after event: String) {
        guard bar.window != nil, bar.bounds.height > 0 else { return }
        bar.layoutIfNeeded()
        let overlaps = overlappingRows
        guard !overlaps.isEmpty else { return }
        logger.error("rows overlap after \(event, privacy: .public): \(overlaps.joined(separator: ", "), privacy: .public)")
    }

    /// 書いていないときのバーの高さを、チューニングの値に揃える。
    private func observeTuning() {
        withObservationTracking {
            restRowHeight.constant = tuning.value(of: TuningCatalog.composeRestingHeight) - restInset * 2
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTuning() }
        }
    }

    // MARK: - モデルの反映

    private func observeModel() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    private func update() {
        // 変換中の文字を消さないよう、入力欄から来た変更は書き戻さない。
        if textView.text != model.text {
            textView.text = model.text
            textDidChange()
        }
        placeholderLabel.isHidden = !model.text.isEmpty

        let replyAcct = model.replyTo.map { "@\($0.displayed.account.acct)" }
        // 札を消すときは、薄くなる間も文字が残るよう、前の文字のままにする。
        if let replyAcct {
            setReplyTitle("\(replyAcct)への返信" + (model.showsSpoiler ? "（注意書き付き）" : ""))
        }
        setReplyRowShown(isEditing && replyAcct != nil)

        let option = VisibilityOption(model.visibility)
        visibilityButton.configuration?.image = UIImage(systemName: option.symbolName)
        visibilityButton.accessibilityLabel = "公開範囲"
        visibilityButton.accessibilityValue = option.title
        visibilityButton.menu = UIMenu(title: "公開範囲", children: VisibilityOption.choices.map { choice in
            UIAction(title: choice.title, image: UIImage(systemName: choice.symbolName), state: choice.visibility == model.visibility ? .on : .off) { [weak self] _ in
                self?.model.choose(choice.visibility)
            }
        })

        remainingLabel.text = "\(model.remainingCharacters)"
        remainingLabel.textColor = model.remainingCharacters < 0 ? .systemRed : .secondaryLabel
        remainingLabel.accessibilityLabel = "残り\(model.remainingCharacters)文字"
        sendButton.isEnabled = model.canPost
        sendButton.configuration?.showsActivityIndicator = model.isPosting
        textView.isEditable = !model.isPosting

        restLabel.attributedText = restText(replyAcct: replyAcct)
        presentErrorIfNeeded()
        logOverlappingRows(after: "update")
    }

    /// 書いている間に札を出したり消したりするときは、パッと切り替えず、札を薄くしながら行を縮める（広げる）。
    /// パッと切り替えると、バーの高さが一瞬で変わり、上端とタイムラインの下の余白が飛んで見える。
    /// 書いていないときは、バーの形を変える動きの中で行を出し入れするので、ここでは動かさない。
    private func setReplyRowShown(_ shown: Bool) {
        guard replyRow.isHidden == shown else { return }
        guard isEditing, bar.window != nil else {
            setRowHidden(replyRow, !shown)
            replyRow.alpha = shown ? 1 : 0
            return
        }
        if shown {
            replyRow.alpha = 0
        }
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeMorphDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.setRowHidden(self.replyRow, !shown)
            self.replyRow.alpha = shown ? 1 : 0
            self.host?.view.layoutIfNeeded()
        }
    }

    /// 札の文字を入れ、札の大きさを測り直させる。
    /// 札は文字のないアイコンだけの大きさで並べられたあと、文字を入れても大きさが変わらず、文字がカプセルの外に切れて見えなくなったことがある
    /// （投稿に返信したあと、同じ投稿のブーストを返信に選び直したとき、実機で起きた）。
    private func setReplyTitle(_ title: String?) {
        if replyButton.configuration?.title != title {
            replyButton.configuration?.title = title
        }
        replyButton.invalidateIntrinsicContentSize()
        replyRow.setNeedsLayout()
    }

    /// 書いていないときに出す下書きの1行。返信なら宛先を札にまとめ、自分で書いた部分だけを続ける。何も書いていなければ書き出しを促す。
    private func restText(replyAcct: String?) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        if let replyAcct {
            let arrow = NSTextAttachment(image: UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) ?? UIImage())
            result.append(NSAttributedString(attachment: arrow))
            result.append(NSAttributedString(string: " \(replyAcct)  "))
            result.addAttributes([.font: font, .foregroundColor: UIColor.tintColor], range: NSRange(location: 0, length: result.length))
        }
        let body = model.typedText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if body.isEmpty {
            result.append(NSAttributedString(string: "いまどうしてる？", attributes: [.font: font, .foregroundColor: UIColor.placeholderText]))
        } else {
            result.append(NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: UIColor.label]))
        }
        return result
    }

    /// 全画面の投稿画面を出している間は、そちらが失敗を知らせる。
    private func presentErrorIfNeeded() {
        guard let message = model.errorMessage, !isPresentingError, let host, host.presentedViewController == nil else { return }
        isPresentingError = true
        let alert = UIAlertController(title: "投稿できませんでした", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.isPresentingError = false
            self?.model.errorMessage = nil
        })
        host.present(alert, animated: true)
    }

    /// 入力が長くなったら、決めた高さまでは伸ばし、超えたら中でスクロールする。
    private func textDidChange() {
        // 幅が決まる前に測ると1文字ずつ折り返した高さになり、短い文でもスクロールに切り替わってしまう。
        guard textView.bounds.width > 0 else { return }
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let scrolls = fitting > maxTextHeight
        if textView.isScrollEnabled != scrolls {
            textView.isScrollEnabled = scrolls
            textHeightLimit.isActive = scrolls
        }
    }

    // MARK: - 部品

    private func configureRestRow() {
        restLabel.lineBreakMode = .byTruncatingTail
        restLabel.translatesAutoresizingMaskIntoConstraints = false
        restRow.addSubview(restLabel)
        NSLayoutConstraint.activate([
            restLabel.leadingAnchor.constraint(equalTo: restRow.leadingAnchor),
            restLabel.trailingAnchor.constraint(equalTo: restRow.trailingAnchor),
            restLabel.centerYAnchor.constraint(equalTo: restRow.centerYAnchor),
            restRowHeight,
        ])
        restRow.addAction(UIAction { [weak self] _ in self?.beginEditing() }, for: .touchUpInside)
        restRow.isAccessibilityElement = true
        restRow.accessibilityLabel = "投稿欄"
        restRow.accessibilityTraits = .button
    }

    private func makeReplyRow() -> UIView {
        replyButton.configuration?.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
        replyButton.configuration?.imagePadding = 4
        replyButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        replyButton.configuration?.titleLineBreakMode = .byTruncatingTail
        replyButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .footnote)
            return attributes
        }
        replyButton.configuration?.cornerStyle = .capsule
        replyButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10)
        replyButton.contentHorizontalAlignment = .leading
        replyButton.accessibilityHint = "タイムラインの返信先の投稿を表示します"
        replyButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        let clear = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.model.setReplyTarget(nil) })
        clear.accessibilityLabel = "返信をやめる"
        clear.setContentHuggingPriority(.required, for: .horizontal)
        // 札は宛先の長さに合わせ、余った幅は札と×の間に空ける。
        replyButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [replyButton, spacer, clear])
        row.alignment = .center
        row.spacing = 6
        return row
    }

    private func configureBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        // 書いていないときは細いカプセル、書いているときは角の丸い板にする。
        bar.cornerConfiguration = .capsule(maximumRadius: 24)
        configureRestRow()
        // キーボードを指に付いて動かせるのは、引いて閉じる設定のスクロールビューを引いたときだけなので、バーの中身をスクロールビューに載せる。
        // 中身は動かさず、指の動きだけをキーボードに伝える。
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        dragArea.keyboardDismissMode = .interactive
        dragArea.alwaysBounceVertical = true
        dragArea.showsVerticalScrollIndicator = false
        dragArea.contentInsetAdjustmentBehavior = .never
        dragArea.delaysContentTouches = false
        dragArea.delegate = self

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.accessibilityLabel = "本文"

        placeholderLabel.text = "いまどうしてる？"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
        ])

        visibilityButton.configuration?.baseForegroundColor = .label
        visibilityButton.showsMenuAsPrimaryAction = true
        var expandConfiguration = UIButton.Configuration.plain()
        expandConfiguration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        expandConfiguration.baseForegroundColor = .label
        let expandButton = UIButton(configuration: expandConfiguration, primaryAction: UIAction { [weak self] _ in self?.expand() })
        expandButton.accessibilityLabel = "広げて書く"

        remainingLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.accessibilityLabel = "投稿"
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [visibilityButton, expandButton, spacer, remainingLabel, sendButton] {
            tools.addArrangedSubview(view)
        }
        tools.alignment = .center
        tools.spacing = 4
        for view in [restRow, replyRow, textView, tools] {
            stack.addArrangedSubview(view)
        }
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(dragArea)
        dragArea.addSubview(stack)
        let content = dragArea.contentLayoutGuide
        let frame = dragArea.frameLayoutGuide
        NSLayoutConstraint.activate([
            dragArea.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor),
            dragArea.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stackTop,
            stackBottom,
            // 中身の大きさをバーの大きさに揃え、バーの高さは中身から決める。
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(equalTo: frame.heightAnchor),
        ])
    }
}

extension InlineComposeController: UITextViewDelegate {
    /// 入力バーを引いても中身は動かさない。入力欄も同じ通知を受けるため、バーのスクロールビューだけを止める。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === dragArea, scrollView.contentOffset != .zero else { return }
        scrollView.contentOffset = .zero
    }

    func textViewDidChange(_ textView: UITextView) {
        model.text = textView.text
        textDidChange()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        setEditing(false)
    }
}

/// Returnは改行と変換の確定に使うため、送信はボタンと、ハードウェアキーボードの⌘Returnだけにする。
private final class ComposeTextView: UITextView {
    var onSubmit: () -> Void = {}

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(title: "投稿", action: #selector(submitFromKeyboard), input: "\r", modifierFlags: .command)
        return (super.keyCommands ?? []) + [submit]
    }

    @objc private func submitFromKeyboard() {
        onSubmit()
    }
}

/// 入力バーの中身を載せるスクロールビュー。ボタンや入力欄の上から引き始めても、キーボードを引けるようにする。
private final class KeyboardDragArea: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }
}

/// 投稿欄のバー。キーボードに付いて動いたときや高さが変わったときに知らせ、覆っている高さを測り直せるようにする。
private final class ComposeBarView: UIVisualEffectView {
    var onFrameChange: () -> Void = {}

    override var center: CGPoint {
        didSet { onFrameChange() }
    }

    override var bounds: CGRect {
        didSet { onFrameChange() }
    }
}

