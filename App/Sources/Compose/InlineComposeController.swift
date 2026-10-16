import Observation
import os
import PhotosUI
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
    /// 書き終えてバーを細いカプセルに戻したときに呼ぶ。メディアを選ぶシートやビューアのためにキーボードを閉じたときは、書いている途中なので呼ばない。
    var onEndEditing: () -> Void = {}
    /// 失敗の知らせや、メディアを選ぶシートを重ねる画面を返す。アプリ内のSafariのシートを出している間は、その上に重ねる必要がある。
    /// 全画面の投稿画面を出している間は、そちらが失敗を知らせるためnilを返す。渡されなければ、何も重ねていないときだけ投稿欄の画面に重ねる。
    var presenterAboveInlineCompose: (() -> UIViewController?)?

    private var presenterForErrors: UIViewController? {
        if let presenterAboveInlineCompose { return presenterAboveInlineCompose() }
        guard let host, host.presentedViewController == nil else { return nil }
        return host
    }
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
    /// 添付したメディアのサムネイルの列。書いていて、添付があるときだけ出す。
    let attachmentStrip = ComposeAttachmentStrip()
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
    private lazy var mediaButton = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.toggleMediaPicker() })
    /// メディアを選ぶシート。出している間だけある。
    private var mediaPicker: MediaPickerSheet?
    /// 最後に出したキーボードの、画面の下端からの高さ。メディアを選ぶシートをこの高さで出す。
    private var lastKeyboardHeight: CGFloat?
    /// メディアを選ぶシートやビューアを出している間、キーボードが閉じてもバーをシート（ビューアならキーボード）の上端の高さに留める。
    /// シートやビューアを閉じてキーボードが上がりきるまで付けておき、バーがタブバーの上に落ちないようにする。
    private var holdAboveKeyboard: NSLayoutConstraint?
    /// 今のキーボードの、画面の下端からの高さ。隠れていれば0。
    private var currentKeyboardHeight: CGFloat = 0
    /// 添付の長押しのメニューを出したときのキーボードの高さ。メニューの間はiOSがソフトウェアキーボードを隠すため、
    /// キーボードがこの高さまで戻るまでバーを今の位置に留める。留めていなければnil。
    private var keyboardHeightBeforeContextMenu: CGFloat?
    /// 添付を開いているビューア。閉じたら（閉じる動きの途中でも）nilにする。
    private weak var mediaViewer: MediaViewerController?
    /// ビューアを開いてから、閉じる動きを終えるまでtrue。この間は、キーボードを閉じても書いている状態を解かない。
    private var isShowingMediaViewer = false
    /// ビューアを開くたびに増やす。閉じる途中に別の添付を開いたら、前のビューアの閉じ終わりでキーボードを戻さないようにする。
    private var mediaViewerGeneration = 0

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
            // シートの上に見えている投稿ボタンから送ったときは、入力欄はもうキーボードを出していないので、シートを閉じて書き終える。
            // 添付したメディアは、下書きと一緒にモデルが空にしている。
            self?.mediaPicker?.close(notifiesWillClose: false)
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
        holdAboveKeyboard = bar.bottomAnchor.constraint(lessThanOrEqualTo: host.view.bottomAnchor)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
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

    /// バーをキーボードに付けず、決めた位置に留めている。
    var isBarHeld: Bool { holdAboveKeyboard?.isActive ?? false }

    /// 違和感レポートに残す状態。行が重なっていれば、どの行かも書く。
    func stateDump() -> String {
        """
        editing: \(isEditing) firstResponder: \(textView.isFirstResponder) replyTo: \(model.replyTo?.id ?? "nil")
        mediaPicker: \(mediaPicker.map { $0.isClosing ? "closing" : "shown" } ?? "nil") mediaViewer: \(mediaViewer != nil ? "shown" : isShowingMediaViewer ? "closing" : "nil") holdAboveKeyboard: \(holdAboveKeyboard?.isActive ?? false) lastKeyboardHeight: \(lastKeyboardHeight.map { "\($0)" } ?? "nil")
        attachments: \(model.attachments.map { "\($0.state)" }.joined(separator: ", "))
        bar.frame: \(bar.frame)
        rows: \(rowStates.map { "\($0.name) hidden=\($0.view.isHidden) frame=\($0.view.frame)" }.joined(separator: ", "))
        overlaps: \(overlappingRows.isEmpty ? "none" : overlappingRows.joined(separator: ", "))
        replyChip: title=\(replyButton.configuration?.title ?? "nil") frame=\(replyButton.frame) label=\(replyButton.titleLabel.map { "text=\($0.text ?? "nil") frame=\($0.frame) alpha=\($0.alpha) hidden=\($0.isHidden)" } ?? "nil")
        """
    }

    private var rowStates: [(name: String, view: UIView)] {
        [("rest", restRow), ("reply", replyRow), ("attachments", attachmentStrip), ("text", textView), ("tools", tools)]
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
        if let mediaPicker {
            // シートを出したままでは全画面の投稿画面を出せないので、閉じ終わってから広げる。
            mediaPicker.onDidClose = { [weak self] in
                self?.mediaPickerDidClose()
                self?.onExpand()
            }
            mediaPicker.close(notifiesWillClose: false)
            return
        }
        textView.resignFirstResponder()
        onExpand()
    }

    private func submit() {
        Task { await model.submit() }
    }

    // MARK: - メディアを選ぶシート

    /// 出していなければシートを出し、出していれば閉じてキーボードに戻る。
    /// スワイプして閉じられなくなったときの逃げ道も兼ねる。シートの上に見えているこのボタンからは、いつでも閉じられる。
    private func toggleMediaPicker() {
        if let mediaPicker {
            // 閉じる途中に押されたら、本来はシートを開き直したい。ただしUIKitは閉じ終わるまで次のシートを出せず、
            // 閉じ終わってから開き直すと、上がってきたキーボードがまた下がる往復になる。どちらが良いか決めていない試作なので、今は押されたことだけを残す。
            guard !mediaPicker.isClosing else {
                logger.info("media picker: button tapped while closing, ignored")
                return
            }
            logger.info("media picker: closing from compose button")
            mediaPicker.close(notifiesWillClose: true)
            return
        }
        presentMediaPicker()
    }

    /// キーボードと同じ高さのシートを出し、バーをその上端に留めたまま、書いている状態を保つ。
    private func presentMediaPicker() {
        guard let host, isEditing, model.canAttachMedia else { return }
        let fixedHeight = tuning.value(of: TuningCatalog.composePickerHeight)
        let matchesKeyboard = tuning.value(of: TuningCatalog.composePickerMatchesKeyboard)
        let height = matchesKeyboard ? (lastKeyboardHeight ?? fixedHeight) : fixedHeight
        setHoldAboveKeyboard(height: height)
        // 独自の高さはシートの下の安全領域を含まないので、その分を引く。
        let picker = MediaPickerSheet(
            selectedIDs: model.attachedAssetIdentifiers,
            selectionLimit: model.maxMediaAttachments,
            lowHeight: height - host.view.safeAreaInsets.bottom
        )
        picker.onSelectionChange = { [weak self] results in
            self?.model.applyPickerSelection(results.compactMap { result in
                result.assetIdentifier.map { LocalMediaLoader.picked(assetIdentifier: $0, provider: result.itemProvider) }
            })
        }
        picker.onWillClose = { [weak self] in self?.textView.becomeFirstResponder() }
        picker.onDidClose = { [weak self] in self?.mediaPickerDidClose() }
        mediaPicker = picker
        logger.info("media picker: presenting (height=\(height), keyboardHeight=\(self.lastKeyboardHeight ?? -1))")
        textView.resignFirstResponder()
        picker.present(from: presenterAboveInlineCompose?() ?? host)
    }

    /// キーボードに戻らずに閉じたとき（全画面に広げたときなど）は、書き終えたときと同じくバーを細いカプセルに戻す。
    private func mediaPickerDidClose() {
        logger.info("media picker: did close (firstResponder=\(self.textView.isFirstResponder))")
        mediaPicker = nil
        model.mediaPickerDidClose()
        // シートを出している間に投稿に失敗していたら、ここで知らせる。
        presentErrorIfNeeded()
        guard !textView.isFirstResponder else { return }
        releaseHoldAboveKeyboard()
        setEditing(false)
    }

    private func setHoldAboveKeyboard(height: CGFloat) {
        guard let holdAboveKeyboard else { return }
        holdAboveKeyboard.constant = -(height + barSpacing)
        holdAboveKeyboard.isActive = true
        animateBarPosition()
    }

    private func releaseHoldAboveKeyboard() {
        guard let holdAboveKeyboard, holdAboveKeyboard.isActive else { return }
        holdAboveKeyboard.isActive = false
        animateBarPosition()
    }

    /// シートの高さとキーボードの高さが違うときに、バーが飛ばずに動くようにする。
    private func animateBarPosition() {
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeMorphDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.host?.view.layoutIfNeeded()
        }
    }

    /// シートをキーボードと同じ高さで出せるよう、キーボードの高さを覚えておく。
    /// ハードウェアキーボードでは候補の段だけになるので、低すぎる高さは覚えない。
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let host, let window = host.view.window,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardTop = host.view.convert(window.convert(frame, from: nil), from: window).minY
        let height = host.view.bounds.maxY - keyboardTop
        currentKeyboardHeight = max(height, 0)
        if let before = keyboardHeightBeforeContextMenu, currentKeyboardHeight >= before {
            releaseBarHeldForContextMenu()
        }
        guard height > 100 else { return }
        lastKeyboardHeight = height
    }

    /// 添付の長押しのメニューを出すと、iOSは入力欄のフォーカスを残したままソフトウェアキーボードを隠す。
    /// バーがキーボードについてタブバーの上まで下がり、メニューを閉じるかドラッグに移ると上がり直すため、メニューの間は今の位置に留める。
    private func holdBarForContextMenu() {
        guard let host, textView.isFirstResponder, mediaPicker == nil, !isShowingMediaViewer else { return }
        logger.info("attachment context menu: holding bar (keyboardHeight=\(self.currentKeyboardHeight))")
        keyboardHeightBeforeContextMenu = currentKeyboardHeight
        setHoldAboveKeyboard(height: host.view.bounds.maxY - bar.frame.maxY - barSpacing)
    }

    /// キーボードが隠れなかったとき（ハードウェアキーボードなど）や、もう戻っているときは、メニューを閉じ始めた時点で外す。
    /// 隠れたままなら、キーボードが戻ったときに外す。
    private func contextMenuWillEnd() {
        guard let before = keyboardHeightBeforeContextMenu, currentKeyboardHeight >= before else { return }
        releaseBarHeldForContextMenu()
    }

    private func releaseBarHeldForContextMenu() {
        guard keyboardHeightBeforeContextMenu != nil else { return }
        logger.info("attachment context menu: releasing bar")
        keyboardHeightBeforeContextMenu = nil
        releaseHoldAboveKeyboard()
    }

    /// シートを閉じてキーボードが上がりきったら、バーをキーボードに付ける。
    @objc private func keyboardDidShow(_ notification: Notification) {
        guard textView.isFirstResponder else { return }
        keyboardHeightBeforeContextMenu = nil
        releaseHoldAboveKeyboard()
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
        let showsAttachments = isEditing && !model.attachments.isEmpty
        setRowHidden(attachmentStrip, !showsAttachments)
        attachmentStrip.alpha = showsAttachments ? 1 : 0
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
        setRowShown(replyRow, isEditing && replyAcct != nil)

        attachmentStrip.update(model.attachments.map { attachment in
            ComposeAttachmentStrip.Item(
                attachment: attachment,
                local: model.localMedia[attachment.id],
                status: model.attachmentStatus(of: attachment.id) ?? .uploading
            )
        })
        mediaViewer?.update(items: viewerItems())
        setRowShown(attachmentStrip, isEditing && !model.attachments.isEmpty)
        mediaButton.configuration?.title = model.attachments.isEmpty ? nil : "\(model.attachments.count)"
        mediaButton.isEnabled = model.canAttachMedia || mediaPicker != nil

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

    /// 書いている間に札やサムネイルの列を出したり消したりするときは、パッと切り替えず、行を薄くしながら縮める（広げる）。
    /// パッと切り替えると、バーの高さが一瞬で変わり、上端とタイムラインの下の余白が飛んで見える。
    /// 書いていないときは、バーの形を変える動きの中で行を出し入れするので、ここでは動かさない。
    private func setRowShown(_ row: UIView, _ shown: Bool) {
        guard row.isHidden == shown else { return }
        guard isEditing, bar.window != nil else {
            setRowHidden(row, !shown)
            row.alpha = shown ? 1 : 0
            return
        }
        if shown {
            row.alpha = 0
        }
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeMorphDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.setRowHidden(row, !shown)
            row.alpha = shown ? 1 : 0
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

    /// 全画面の投稿画面やメディアを選ぶシートなどを出している間は出さない。全画面の投稿画面は、そちらが失敗を知らせる。
    private func presentErrorIfNeeded() {
        guard let message = model.errorMessage, !isPresentingError, let presenter = presenterForErrors, presenter.presentedViewController == nil else { return }
        isPresentingError = true
        let alert = UIAlertController(title: "投稿できませんでした", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.isPresentingError = false
            self?.model.errorMessage = nil
        })
        presenter.present(alert, animated: true)
    }

    // MARK: - 添付のビューア

    /// 添付を押したら、タイムラインと同じビューアで開く。失敗したものも開き、上の中央の失敗の表示から理由と送り直す操作を出す。
    ///
    /// ビューアは表示されると最初の応答者になるため、何もしないとキーボードが下がって投稿欄がカプセルに戻り、サムネイルの列が隠れて閉じる画像の戻り先がなくなる。
    /// 開く前に自分でキーボードを閉じ、バーをキーボードの高さに留め、開いている間は書いている状態を解かない。
    /// 入力欄を最初の応答者のまま開くと、閉じた時点でUIKitが入力欄にキーボードを戻し、閉じ始めの画像が止まって見えたため、キーボードは閉じる動きが終わってから戻す。
    private func openAttachment(_ id: DraftAttachment.ID) {
        guard let host, isEditing, let index = model.attachments.firstIndex(where: { $0.id == id }) else { return }
        guard mediaViewer == nil else {
            logger.info("open attachment viewer ignored: viewer is still shown")
            return
        }
        logger.info("open attachment viewer index=\(index, privacy: .public) count=\(self.model.attachments.count, privacy: .public)")
        mediaViewerGeneration += 1
        let generation = mediaViewerGeneration
        isShowingMediaViewer = true
        if mediaPicker == nil, textView.isFirstResponder {
            if let lastKeyboardHeight {
                setHoldAboveKeyboard(height: lastKeyboardHeight)
            }
            textView.resignFirstResponder()
        }
        let viewer = MediaViewerController(
            items: viewerItems(),
            startIndex: index,
            store: AppDependencies.mediaImages,
            dragToDismiss: TuningCatalog.dragToDismiss(in: tuning),
            // バーの奥と手前の描き分けは、タイムラインの一覧のバーのためのもので、投稿欄のサムネイルには使わない。
            timing: MediaViewerController.Timing(tuning: tuning, drawsUnderBars: false),
            editing: MediaViewerController.Editing(
                descriptionLimit: model.mediaDescriptionLimit,
                descriptionRemainingThreshold: Int(tuning.value(of: TuningCatalog.mediaDescriptionRemainingThreshold)),
                descriptionMaxLines: Int(tuning.value(of: TuningCatalog.mediaDescriptionMaxLines)),
                menuElements: { [weak self] itemID in self?.viewerMenuElements(for: itemID) ?? [] },
                commitDescription: { [weak self] itemID, text in
                    guard let id = UUID(uuidString: itemID) else { return }
                    self?.model.setDescription(text, of: id)
                },
                showFailure: { [weak self] itemID, presenter in
                    guard let id = UUID(uuidString: itemID) else { return }
                    self?.presentAttachmentFailure(id, from: presenter)
                }
            ),
            sourceTile: { [weak self] itemID in
                UUID(uuidString: itemID).flatMap { self?.attachmentStrip.tile(for: $0) }
            }
        )
        // 閉じたビューアがすぐには解放されず、weakの参照がnilに戻るのを待つと、2回目からサムネイルを押しても開けなかった（シミュレーターで確認）。
        // 解放されない原因は調べていない。開いているかの判断は解放に頼らず、閉じた時点で参照を外して決める。
        viewer.onDismiss = { [weak self] in self?.mediaViewer = nil }
        viewer.onCloseFinish = { [weak self] in self?.mediaViewerDidFinishClosing(generation: generation) }
        mediaViewer = viewer
        // Macで動かしていても別ウィンドウにはせず、その場で開く。別のシーンと下書きをつながずに済ませるため。
        // ピッカーのシートを出していれば、その上に開き、閉じるとシートと投稿欄はそのまま残る。
        topPresenter(from: host).present(viewer, animated: false)
    }

    /// 閉じる動きが終わったら、入力欄にキーボードを戻す。ピッカーのシートを出していれば、シートの上に戻ったのでキーボードは出さない。
    private func mediaViewerDidFinishClosing(generation: Int) {
        guard generation == mediaViewerGeneration else { return }
        logger.info("attachment viewer did finish closing (picker=\(self.mediaPicker != nil))")
        isShowingMediaViewer = false
        guard mediaPicker == nil, isEditing else { return }
        textView.becomeFirstResponder()
    }

    /// ビューアのメニューで、「代替テキストを編集」に続けて出す項目。失敗したものには「再試行」も出す。
    private func viewerMenuElements(for itemID: String) -> [UIMenuElement] {
        guard let id = UUID(uuidString: itemID), let status = model.attachmentStatus(of: id) else { return [] }
        var elements: [UIMenuElement] = []
        if status == .failed || status == .descriptionFailed {
            elements.append(UIAction(title: "再試行", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.model.retryAttachment(id)
            })
        }
        elements.append(UIAction(title: "削除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.removeAttachment(id)
        })
        return elements
    }

    /// 失敗の理由と、送り直すか外すかを、`presenter`の上に出す。
    private func presentAttachmentFailure(_ id: DraftAttachment.ID, from presenter: UIViewController) {
        guard let status = model.attachmentStatus(of: id), status == .failed || status == .descriptionFailed else { return }
        let local = model.localMedia[id]
        let failure = status == .failed ? local?.failure : local?.descriptionFailure
        let title = status == .failed ? "アップロードできませんでした" : "代替テキストを送信できませんでした"
        let alert = UIAlertController(title: title, message: failure.map { ErrorPresentation($0).text }, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self] _ in self?.model.retryAttachment(id) })
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in self?.removeAttachment(id) })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// 添付を外す。ピッカーを出していれば、その選択からも外す。
    /// ビューアから外すときは、先にビューアを閉じ始め、戻り先のサムネイルが消えたら画像はその場で薄くなる。列の長押しから外すときはビューアを開いていない。
    private func removeAttachment(_ id: DraftAttachment.ID) {
        mediaViewer?.close()
        if let assetIdentifier = model.localMedia[id]?.assetIdentifier {
            mediaPicker?.deselect([assetIdentifier])
        }
        model.removeAttachment(id, pickerIsOpen: mediaPicker != nil)
    }

    /// ビューアで見せる中身。種類はファイルを読み込むまで分からないため、それまでは画像として扱う。
    private func viewerItems() -> [MediaViewerItem] {
        model.attachments.map { attachment in
            let local = model.localMedia[attachment.id]
            return MediaViewerItem(
                id: attachment.id.uuidString,
                kind: local?.file?.kind ?? .image,
                description: attachment.description,
                file: local?.file,
                thumbnail: local?.thumbnail,
                status: model.attachmentStatus(of: attachment.id) ?? .uploading
            )
        }
    }

    /// いちばん手前に出している画面。閉じている途中のものは除く。
    private func topPresenter(from host: UIViewController) -> UIViewController {
        var presenter = host
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
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
            // スクロールを止めても、入力欄は本来の高さを測り直さない。測り直させないと、5行から4行に減らしたときに入力欄が潰れ、下のボタンの行に重なった。
            textView.invalidateIntrinsicContentSize()
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
        mediaButton.configuration?.image = UIImage(systemName: "photo.on.rectangle")
        mediaButton.configuration?.baseForegroundColor = .label
        mediaButton.configuration?.imagePadding = 4
        mediaButton.accessibilityLabel = "メディアを添付"
        for view in [visibilityButton, mediaButton, expandButton, spacer, remainingLabel, sendButton] {
            tools.addArrangedSubview(view)
        }
        tools.alignment = .center
        tools.spacing = 4
        attachmentStrip.onSelect = { [weak self] id in self?.openAttachment(id) }
        attachmentStrip.onMove = { [weak self] id, index in self?.model.moveAttachment(id, to: index) }
        attachmentStrip.onRemove = { [weak self] id in self?.removeAttachment(id) }
        attachmentStrip.onContextMenuWillShow = { [weak self] in self?.holdBarForContextMenu() }
        attachmentStrip.onContextMenuWillEnd = { [weak self] in self?.contextMenuWillEnd() }
        for view in [restRow, replyRow, attachmentStrip, textView, tools] {
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

    /// シートを出している間に入力欄に触れたら、シートを閉じてキーボードに戻る。
    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let mediaPicker, !mediaPicker.isClosing else { return }
        logger.info("media picker: closing because text view began editing")
        mediaPicker.close(notifiesWillClose: false)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // メディアを選ぶシートを出すためにキーボードを閉じたときは、書いている状態のままにする。
        // 添付のビューアを開くためにキーボードを閉じたときも同じ。閉じ終わったら入力欄にキーボードを戻す。
        // シートを閉じたあとに書き終えたときは、キーボードが上がりきった知らせが来ずにバーを留めたままでも、カプセルに戻す。
        guard mediaPicker == nil, !isShowingMediaViewer else { return }
        releaseHoldAboveKeyboard()
        setEditing(false)
        onEndEditing()
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

