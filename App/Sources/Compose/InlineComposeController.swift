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
    /// 本文と注意書きの補完。本文ではメンション、ハッシュタグ、カスタム絵文字を、注意書きではカスタム絵文字だけを補完する。
    /// サーバーは注意書きのメンションとハッシュタグを読まないため。
    let completion: ComposeCompletion
    /// 編集を始めるときに呼ぶ。既定の公開範囲などをまだ読めていなければ読む。
    var onBeginEditing: () -> Void = {}
    /// 書き終えてバーを細いカプセルに戻したときに呼ぶ。メディアを選ぶシートやビューアのためにキーボードを閉じたときは、書いている途中なので呼ばない。
    var onEndEditing: () -> Void = {}
    /// 失敗の知らせや、メディアを選ぶシートを重ねる画面を返す。アプリ内のSafariのシートを出している間は、その上に重ねる必要がある。
    /// ほかの画面を出している間はnilを返す。渡されなければ、何も重ねていないときだけ投稿欄の画面に重ねる。
    var presenterAboveInlineCompose: (() -> UIViewController?)?

    private var presenterForErrors: UIViewController? {
        if let presenterAboveInlineCompose { return presenterAboveInlineCompose() }
        guard let host, host.presentedViewController == nil else { return nil }
        return host
    }
    /// 返信先の札を押したときに呼ぶ。返信先の投稿を見せる。
    var onShowReplyTarget: (Status) -> Void = { _ in }
    /// 投稿できたあとに呼ぶ。
    var onPosted: () -> Void = {}
    /// 画面の下端から、投稿欄（書いているときはキーボードも）が覆っている高さが変わったときに呼ぶ。
    var onObscuredHeightChange: (CGFloat) -> Void = { _ in }

    private weak var host: UIViewController?
    private let tuning: TuningStore
    private let settings: AppSettings
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
    /// 注意書きの入力欄。＋のメニューから足したときと、注意書きの付いた投稿へ返信したときだけ、本文の上に出す。
    private let spoilerField = ComposeSpoilerField()
    private lazy var spoilerRow = makeSpoilerRow()
    /// 注意書きの欄を閉じるボタン。閲覧注意も一緒に外れる。
    private let spoilerClearButton = UIButton(type: .system)
    private let textView = ComposeTextView()
    /// 最後にキーボードを出していた入力欄。シートやビューアを閉じたら、ここへキーボードを戻す。
    private weak var lastFocusedInput: UIView?
    /// 本文と注意書きの間でフォーカスを移している最中。移す前の入力欄の編集が終わっても、書き終えたとして扱わない。
    private var isMovingFocus = false
    private let placeholderLabel = UILabel()
    /// 書き終えて入力欄を隠すと、スタックビューが高さ0の制約を付ける。それと競合しないよう、必須より1つ下げる。
    private lazy var textHeightLimit: NSLayoutConstraint = {
        let constraint = textView.heightAnchor.constraint(equalToConstant: maxTextHeight)
        constraint.priority = .required - 1
        return constraint
    }()
    private let visibilityButton = UIButton(configuration: .plain())
    private lazy var expandButton = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.toggleExpanded() })
    /// 展開ボタンで広げている。本文の5行の上限を外し、バーの上端を上の安全領域の上端に付ける。
    private var isExpanded = false
    /// 広げている間だけ付ける、バーの上端を上の安全領域の上端に揃える制約。
    private var expandedTop: NSLayoutConstraint?
    /// 広げた状態から戻す動きの間はtrue。この間は本文をスクロールできるままにし、高さだけを本文に合わせる。
    private var isCollapsingFromExpanded = false
    /// 広げる・戻すたびに増やす。前の動きの終わりで、次の戻す動きの途中に本文のスクロールを切り替えないようにする。
    private var expansionGeneration = 0
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
    private let tools = ComposeToolsView()
    /// 入力バーの中身を載せるスクロールビュー。バーを下へ引くと、キーボードが指に付いて下がる。
    private let dragArea = KeyboardDragArea()
    /// 添付などの部品を足す項目をまとめたメニューのボタン。書いていないときや短い投稿のときに、欄を部品のボタンで大きくしないため、1つにまとめる。
    private let addButton = UIButton(configuration: .plain())
    /// 部品を足す項目のうち、設定でボタンの行に常に出すもののボタン。行に入りきらなければ隠し、＋のメニューに回す。
    private lazy var toolButtons: [ComposeToolItem: UIButton] = Dictionary(uniqueKeysWithValues: ComposeToolItem.allCases.map { item in
        switch item {
        case .visibility: (item, visibilityButton)
        case .expand: (item, expandButton)
        case .media, .spoiler, .customize: (item, makeToolButton(item))
        }
    })
    /// 今のボタンの行と＋のメニューへの振り分け。ボタンの行の幅が決まるたびに決め直す。まだ一度も振り分けていなければnil。
    /// 全部を非表示にした振り分けは行も＋も空になるので、空の値を初期値にすると、最初の振り分けを済んだものとして飛ばしてしまう。
    private var toolPlacement: ComposeToolPlacement?
    private var isToolPlacementScheduled = false
    /// メディアを選ぶシート。出している間だけある。
    private var mediaPicker: MediaPickerSheet?
    /// 最後に出したキーボードの、画面の下端からの高さ。メディアを選ぶシートをこの高さで出す。
    private var lastKeyboardHeight: CGFloat?
    /// メディアを選ぶシートやビューアを出している間、キーボードが閉じてもバーをシート（ビューアならキーボード）の上端の高さに留める。
    /// シートやビューアを閉じてキーボードが上がりきるまで付けておき、バーがタブバーの上に落ちないようにする。
    private var holdAboveKeyboard: NSLayoutConstraint?
    /// 今のキーボードの、画面の下端からの高さ。隠れていれば0。
    private var currentKeyboardHeight: CGFloat = 0
    /// キーボードの高さがこれ以下なら、ソフトウェアキーボードは出ていない。ハードウェアキーボードでは候補の段だけになる。
    private static let softwareKeyboardMinimumHeight: CGFloat = 100
    /// 添付の長押しのメニューを出したときのキーボードの高さ。メニューの間はiOSがソフトウェアキーボードを隠すため、
    /// キーボードがこの高さまで戻るまでバーを今の位置に留める。留めていなければnil。
    private var keyboardHeightBeforeContextMenu: CGFloat?
    /// 添付を開いているビューア。閉じたら（閉じる動きの途中でも）nilにする。
    private weak var mediaViewer: MediaViewerController?
    /// ビューアを開いてから、閉じる動きを終えるまでtrue。この間は、キーボードを閉じても書いている状態を解かない。
    private var isShowingMediaViewer = false
    /// 書いている途中に並びを変える画面を開いてから、閉じるまでtrue。この間は、キーボードを閉じても書いている状態を解かない。
    private var isShowingToolLayoutSettings = false
    /// ビューアを開くたびに増やす。閉じる途中に別の添付を開いたら、前のビューアの閉じ終わりでキーボードを戻さないようにする。
    private var mediaViewerGeneration = 0
    /// 補完の候補の一覧。タイムラインに重ねて欄の上に出し、広げているときは打っている行のすぐ下に重ねる。
    private let completionList = ComposeCompletionList()
    /// 広げていないときの、一覧の下端を欄の上端に付ける制約。
    private var completionListAboveBar: NSLayoutConstraint?
    /// 広げているときの、一覧の上端の位置。打っている行に合わせて決める。
    private var completionListTop: NSLayoutConstraint?
    private var completionListHeight: NSLayoutConstraint?
    /// 一覧を出している（消える動きの途中はfalse）。
    private var isCompletionListShown = false
    /// 補完している入力欄。本文か注意書き。
    private weak var completionInput: (any UITextInput)?
    /// 補完している入力欄に、最後に本文が変わったとき変換中の文字があった。
    private var completionInputHadMarkedText = false
    /// 一覧と欄や打っている行との間。
    private let completionListSpacing: CGFloat = 6

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

    init(model: ComposeModel, completion: ComposeCompletion? = nil, tuning: TuningStore = AppDependencies.tuning, settings: AppSettings = AppDependencies.settings) {
        self.model = model
        self.completion = completion ?? ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: tuning))
        self.tuning = tuning
        self.settings = settings
        super.init()
        model.onPosted = { [weak self] in
            // シートの上に見えている投稿ボタンから送ったときは、入力欄はもうキーボードを出していないので、シートを閉じて書き終える。
            // 添付したメディアは、下書きと一緒にモデルが空にしている。
            guard let self else { return }
            mediaPicker?.close(notifiesWillClose: false)
            resignInput()
            // 送っている間に添付のビューアを開いていると、入力欄はもうキーボードを出しておらず、書き終えたことにならない。
            // ビューアを閉じるのを待たずにここで書き終え、閉じたあとに空になった本文へキーボードを戻さないようにする。
            if isEditing, mediaPicker == nil {
                releaseHoldAboveKeyboard()
                setEditing(false)
                onEndEditing()
            }
            onPosted()
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
        expandedTop = bar.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
        bar.onFrameChange = { [weak self] in
            self?.reportObscuredHeight()
            self?.layoutCompletionListIfShown()
        }
        installCompletionList(in: host)
        AppDependencies.stateDumps.register("composer", owner: self) { $0.stateDump() }
        applyEditingLayout()
        applyExpandedLayout()
        observeModel()
        observeTuning()
        observeToolLayout()
        observeCompletion()
    }

    /// バーを広げて、キーボードを出す。
    func beginEditing() {
        onBeginEditing()
        completion.prefetch()
        setEditing(true)
        // 書いていない間に下書きが変わっていても、出す前に高さを合わせる。
        bar.layoutIfNeeded()
        textDidChange()
        textView.becomeFirstResponder()
    }

    /// キーボードを閉じて、バーを細いカプセルに戻す。
    func endEditing() {
        resignInput()
    }

    /// 本文か注意書きの入力欄が、キーボードを出している。
    private var isInputFocused: Bool { textView.isFirstResponder || spoilerField.isFirstResponder }

    private func resignInput() {
        textView.resignFirstResponder()
        spoilerField.resignFirstResponder()
    }

    /// 最後に書いていた入力欄にキーボードを戻す。注意書きの欄を外していれば本文に戻す。
    private func focusLastInput() {
        if lastFocusedInput === spoilerField, model.showsSpoiler {
            spoilerField.becomeFirstResponder()
        } else {
            textView.becomeFirstResponder()
        }
    }

    /// バーをキーボードに付けず、決めた位置に留めている。
    var isBarHeld: Bool { holdAboveKeyboard?.isActive ?? false }

    /// 違和感レポートに残す状態。行が重なっていれば、どの行かも書く。
    func stateDump() -> String {
        """
        editing: \(isEditing) expanded: \(isExpanded) firstResponder: \(textView.isFirstResponder ? "text" : spoilerField.isFirstResponder ? "spoiler" : "none") spoiler: \(model.showsSpoiler) sensitive: \(model.isSensitive) replyTo: \(model.replyTo?.id ?? "nil")
        mediaPicker: \(mediaPicker.map { $0.isClosing ? "closing" : "shown" } ?? "nil") mediaViewer: \(mediaViewer != nil ? "shown" : isShowingMediaViewer ? "closing" : "nil") holdAboveKeyboard: \(holdAboveKeyboard?.isActive ?? false) lastKeyboardHeight: \(lastKeyboardHeight.map { "\($0)" } ?? "nil")
        attachments: \(model.attachments.map { "\($0.state)" }.joined(separator: ", "))
        tools: row=\(toolPlacement.map { "\($0.row.map(\.rawValue))" } ?? "nil") menu=\(toolPlacement.map { "\($0.menu.map { $0.map(\.rawValue) })" } ?? "nil")
        bar.frame: \(bar.frame)
        rows: \(rowStates.map { "\($0.name) hidden=\($0.view.isHidden) frame=\($0.view.frame)" }.joined(separator: ", "))
        overlaps: \(overlappingRows.isEmpty ? "none" : overlappingRows.joined(separator: ", "))
        completion: input=\(completionInput === textView ? "text" : completionInput === spoilerField ? "spoiler" : "none") kind=\(completion.token?.kind.rawValue ?? "nil") content=\(completionContentSummary) shown=\(isCompletionListShown) list.frame=\(completionList.frame)
        replyChip: title=\(replyButton.configuration?.title ?? "nil") frame=\(replyButton.frame) label=\(replyButton.titleLabel.map { "text=\($0.text ?? "nil") frame=\($0.frame) alpha=\($0.alpha) hidden=\($0.isHidden)" } ?? "nil")
        """
    }

    private var rowStates: [(name: String, view: UIView)] {
        [("rest", restRow), ("reply", replyRow), ("spoiler", spoilerRow), ("attachments", attachmentStrip), ("text", textView), ("tools", tools)]
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

    /// 本文の長さに関係なく、すぐバーの上端を上の安全領域の上端まで広げる。広げていれば、本文の5行の上限がある高さに戻す。
    /// 打つたびにバーの上端が動かないよう、本文に合わせて伸ばすことはしない。
    private func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded {
            UserAction.expandCompose.record()
        }
        logger.info("compose: \(self.isExpanded ? "expand" : "collapse", privacy: .public)")
        let generation = beginExpansionChange()
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeExpandDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.applyExpandedLayout()
            self.host?.view.layoutIfNeeded()
            // 5行の高さに戻すと、本文が先頭に戻ってカーソルが隠れることがあるため、カーソルの行を見せる。
            self.textView.scrollRangeToVisible(self.textView.selectedRange)
            // 補完の一覧も、同じ動きで、動いたあとの欄と打っている行の位置へ動かす（広げると打っている行の下へ、戻すと欄の上へ）。
            // 動き終わってから置き直すと、動きの間、広げるときは欄の上端に付いて画面の外へ押し出され、戻すときは上端に取り残された。
            // 上で並べ直した時点で、欄と打っている行の位置は動いたあとの値になっている。
            // 一覧の指定は、上の並べ直しの途中（欄が動いた知らせ）で切り替わることがあり、その回の並べ直しには反映されない。
            // 決め直したうえで並べ直しをはっきり求め、この動きの中で一覧を動かす。
            self.layoutCompletionListIfShown()
            self.host?.view.setNeedsLayout()
            self.host?.view.layoutIfNeeded()
        } completion: { _ in
            self.endCollapse(generation: generation)
            // 戻したあとに本文の高さが決め直されると欄の高さも変わるので、置き直す。
            self.layoutCompletionListIfShown()
        }
    }

    /// 広げるか戻すかを決めたあと、動かす前に呼ぶ。戻すときは、動き終わるまで本文をスクロールできるままにする。
    private func beginExpansionChange() -> Int {
        expansionGeneration += 1
        isCollapsingFromExpanded = !isExpanded
        return expansionGeneration
    }

    /// 戻す動きが終わったら、本文の長さに合わせて、伸ばすかスクロールするかを決め直す。
    private func endCollapse(generation: Int) {
        guard generation == expansionGeneration, isCollapsingFromExpanded else { return }
        isCollapsingFromExpanded = false
        textDidChange()
    }

    /// 広げている間は、本文が残りの高さを使い、超えたら中でスクロールする。
    private func applyExpandedLayout() {
        expandedTop?.isActive = isExpanded
        expandButton.configuration?.image = UIImage(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        expandButton.accessibilityLabel = isExpanded ? "元の大きさに戻す" : "広げて書く"
        textDidChange()
    }

    private func submit() {
        Task { await model.submit() }
    }

    // MARK: - ＋のメニュー

    /// ＋のメニューの項目。設定の区切り線で分けたまとまりごとに、区切って並べる。
    private func addMenuElements() -> [UIMenuElement] {
        (toolPlacement?.menu ?? []).map { group in
            UIMenu(options: .displayInline, children: group.map(menuAction(for:)))
        }
    }

    /// 設定と同じ、投稿欄のボタンの並びを変える画面を重ねる。書いている途中なら、閉じたあとにキーボードを戻す。
    /// 開いている間は、キーボードを閉じても書いている状態を解かない。添付のビューアと同じ扱い。
    private func presentToolLayoutSettings() {
        guard let host else { return }
        // ほかの画面が閉じていく途中は、その画面を出していた画面にまだ次の画面を重ねられず、出そうとしても出ない。
        // 開いた扱いだけが残ると、以後キーボードを閉じても欄がカプセルに戻らなくなるため、何もしない。
        // 閉じる動きが始まると、UIKitは閉じていく画面を重ねている画面として返さなくなるので、切り替えの最中かどうかで見分ける。
        let presenter = topPresenter(from: host)
        guard presenter.presentedViewController == nil, presenter.transitionCoordinator == nil else {
            logger.info("compose: tool layout settings ignored while another sheet is closing")
            return
        }
        let resumesEditing = isEditing
        logger.info("compose: present tool layout settings (editing=\(resumesEditing))")
        isShowingToolLayoutSettings = resumesEditing
        resignInput()
        let sheet = ComposeToolLayoutSheet(settings: settings) { [weak self] in
            self?.toolLayoutSettingsDidClose(resumesEditing: resumesEditing)
        }
        presenter.present(sheet, animated: true)
        // それでも出せなかったら、開いた扱いを取り消してキーボードを戻す。
        guard presenter.presentedViewController !== sheet else { return }
        logger.error("compose: tool layout settings could not be presented")
        isShowingToolLayoutSettings = false
        if resumesEditing {
            focusLastInput()
        }
    }

    private func toolLayoutSettingsDidClose(resumesEditing: Bool) {
        logger.info("compose: tool layout settings closed")
        isShowingToolLayoutSettings = false
        guard resumesEditing, isEditing else { return }
        focusLastInput()
    }

    private func menuAction(for item: ComposeToolItem) -> UIMenuElement {
        switch item {
        case .visibility:
            // 選んでいる公開範囲が分かるよう、サブメニューの項目に今の値を添える。
            let menu = UIMenu(title: item.title, subtitle: VisibilityOption(model.visibility).title, image: UIImage(systemName: VisibilityOption(model.visibility).symbolName), children: visibilityActions())
            return menu
        case .customize:
            return UIAction(title: item.title, image: UIImage(systemName: item.symbolName)) { [weak self] _ in
                self?.presentToolLayoutSettings()
            }
        case .expand:
            return UIAction(title: isExpanded ? "元の大きさに戻す" : item.title, image: UIImage(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : item.symbolName)) { [weak self] _ in
                self?.toggleExpanded()
            }
        case .media:
            // シートを出している間は、同じ項目でシートを閉じてキーボードに戻れるようにする。
            let action = mediaPicker == nil
                ? UIAction(title: item.title, image: UIImage(systemName: item.symbolName)) { [weak self] _ in self?.toggleMediaPicker() }
                : UIAction(title: "キーボードに戻る", image: UIImage(systemName: "keyboard")) { [weak self] _ in self?.toggleMediaPicker() }
            if mediaPicker == nil, !model.canAttachMedia {
                action.attributes = .disabled
            }
            return action
        case .spoiler:
            // 添付があれば、注意書きの欄を出すと閲覧注意にもなることを添える。
            let action = UIAction(title: item.title, image: UIImage(systemName: item.symbolName), state: model.showsSpoiler ? .on : .off) { [weak self] _ in
                self?.toggleSpoiler()
            }
            if !model.attachments.isEmpty {
                action.subtitle = "添付も閲覧注意にします"
            }
            return action
        }
    }

    private func visibilityActions() -> [UIAction] {
        VisibilityOption.choices.map { choice in
            UIAction(title: choice.title, image: UIImage(systemName: choice.symbolName), state: choice.visibility == model.visibility ? .on : .off) { [weak self] _ in
                self?.model.choose(choice.visibility)
            }
        }
    }

    private func toggleSpoiler() {
        setSpoilerShown(!model.showsSpoiler)
    }

    // MARK: - ボタンの行に出す部品のボタン

    /// 添付、注意書き、カスタマイズのボタン。公開範囲と展開は、＋を置く前からあるボタンをそのまま使う。
    private func makeToolButton(_ item: ComposeToolItem) -> UIButton {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
            switch item {
            case .media: self?.toggleMediaPicker()
            case .spoiler: self?.toggleSpoiler()
            case .customize: self?.presentToolLayoutSettings()
            case .visibility, .expand: break
            }
        })
        button.configuration?.image = UIImage(systemName: item.symbolName)
        button.configuration?.baseForegroundColor = .label
        button.configuration?.imagePadding = 4
        button.accessibilityLabel = item.title
        button.isHidden = true
        return button
    }

    /// ボタンの状態を下書きに合わせる。添付は枚数を添え、注意書きは付けている間だけ色を付ける。
    private func updateToolButtons() {
        if let media = toolButtons[.media] {
            media.configuration?.title = model.attachments.isEmpty ? nil : "\(model.attachments.count)"
            media.isEnabled = model.canAttachMedia || mediaPicker != nil
        }
        if let spoiler = toolButtons[.spoiler] {
            spoiler.configuration?.baseForegroundColor = model.showsSpoiler ? .tintColor : .label
            spoiler.accessibilityTraits = model.showsSpoiler ? [.button, .selected] : .button
            spoiler.accessibilityValue = model.isSensitive ? "添付も閲覧注意" : nil
        }
    }

    /// 設定の並びが変わったら、ボタンを並びの順に置き直し、振り分けを決め直す。
    private func observeToolLayout() {
        withObservationTracking {
            arrangeToolButtons(settings.composeToolLayout)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeToolLayout() }
        }
    }

    private func arrangeToolButtons(_ layout: MenuLayout<ComposeToolItem>) {
        // ＋をいちばん左に置き、その後ろに項目のボタンを並びの順に置く。
        tools.insertArrangedSubview(addButton, at: 0)
        var index = 1
        for element in layout.elements {
            guard case .item(let item, _) = element, let button = toolButtons[item] else { continue }
            tools.insertArrangedSubview(button, at: index)
            index += 1
        }
        tools.setNeedsLayout()
        placeTools()
    }

    /// ボタンの行に常に出す項目のうち、行に入りきらない分を＋のメニューへ回す。幅は文字の大きさや残り文字数の桁で変わるので、行を並べ直すたびに決め直す。
    private func placeTools() {
        // 書いていないときは行を隠していて幅が決まらないので、決め直さない。
        guard !tools.isHidden, tools.bounds.width > 0 else { return }
        let fixed = [remainingLabel, sendButton].map { $0.intrinsicContentSize.width }.reduce(0, +)
        // 間を埋める空き、残り文字数、送信の間の2つの間隔。項目と＋のボタンは、それぞれ後ろの間隔1つ分を足す。
        let available = tools.bounds.width - fixed - tools.spacing * 2
        let placement = ComposeToolPlacement(
            layout: settings.composeToolLayout,
            available: available,
            addButtonWidth: addButton.intrinsicContentSize.width + tools.spacing,
            width: { [toolButtons, tools] item in (toolButtons[item]?.intrinsicContentSize.width ?? 0) + tools.spacing }
        )
        guard placement != toolPlacement else { return }
        logger.info("compose tools: row=\(placement.row.map(\.rawValue), privacy: .public) menu=\(placement.menu.map { $0.map(\.rawValue) }, privacy: .public) available=\(available)")
        toolPlacement = placement
        for (item, button) in toolButtons {
            setRowHidden(button, !placement.row.contains(item))
        }
        setRowHidden(addButton, !placement.showsAddButton)
    }

    /// 行を並べ終えてから振り分けを決め直す。並べている最中にボタンを出したり隠したりすると、スタックビューが別のボタンを幅0で並べ、出したボタンと重なった。
    private func placeToolsAfterLayout() {
        guard !isToolPlacementScheduled else { return }
        isToolPlacementScheduled = true
        Task { @MainActor [weak self] in
            self?.isToolPlacementScheduled = false
            self?.placeTools()
        }
    }

    // MARK: - 注意書き

    /// 注意書きの欄を出して書き始めるか、外して本文に戻る。外しても書いた注意書きは残し、もう一度足すと戻る。投稿には付けない。
    private func setSpoilerShown(_ shown: Bool) {
        logger.info("compose: spoiler \(shown ? "shown" : "hidden", privacy: .public)")
        if shown {
            model.showsSpoiler = true
            // モデルの変更が画面に届くのは少しあとなので、欄を出してからフォーカスを移す。
            update()
            // シートを出している間は、シートを閉じてから注意書きの欄にキーボードを出す。
            lastFocusedInput = spoilerField
            if mediaPicker == nil {
                spoilerField.becomeFirstResponder()
            } else {
                mediaPicker?.close(notifiesWillClose: true)
            }
        } else {
            model.showsSpoiler = false
            update()
        }
    }

    // MARK: - メディアを選ぶシート

    /// 出していなければシートを出し、出していれば閉じてキーボードに戻る。
    /// スワイプして閉じられなくなったときの逃げ道も兼ねる。シートの上に見えている＋のメニューからは、いつでも閉じられる。
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
        picker.onWillClose = { [weak self] in self?.focusLastInput() }
        picker.onDidClose = { [weak self] in self?.mediaPickerDidClose() }
        mediaPicker = picker
        logger.info("media picker: presenting (height=\(height), keyboardHeight=\(self.lastKeyboardHeight ?? -1))")
        resignInput()
        picker.present(from: presenterAboveInlineCompose?() ?? host)
    }

    /// キーボードに戻らずに閉じたとき（シートの上の投稿ボタンから送ったときなど）は、書き終えたときと同じくバーを細いカプセルに戻す。
    private func mediaPickerDidClose() {
        logger.info("media picker: did close (firstResponder=\(self.isInputFocused))")
        mediaPicker = nil
        model.mediaPickerDidClose()
        // シートを出している間に投稿に失敗していたら、ここで知らせる。知らせはキーボードに戻った入力欄を一度閉じるので、戻ったかは知らせる前に見る。
        let returnedToKeyboard = isInputFocused
        // ハードウェアキーボードではキーボードが上がらず、上がりきった知らせも来ないので、待たずにバーをシートの上端から外す。
        if returnedToKeyboard, currentKeyboardHeight <= Self.softwareKeyboardMinimumHeight {
            releaseHoldAboveKeyboard()
        }
        presentErrorIfNeeded()
        guard !returnedToKeyboard else { return }
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
        // 上端だけで測ると、大きさのない枠（原点が画面の左上）が届いたときに、画面の高さだけ上がったことになる。画面と重なる部分の高さで測る。
        let keyboardFrame = host.view.convert(window.convert(frame, from: nil), from: window)
        let height = host.view.bounds.intersection(keyboardFrame).height
        currentKeyboardHeight = height
        if let before = keyboardHeightBeforeContextMenu, currentKeyboardHeight >= before {
            releaseBarHeldForContextMenu()
        }
        guard height > Self.softwareKeyboardMinimumHeight else { return }
        lastKeyboardHeight = height
    }

    /// 添付の長押しのメニューを出すと、iOSは入力欄のフォーカスを残したままソフトウェアキーボードを隠す。
    /// バーがキーボードについてタブバーの上まで下がり、メニューを閉じるかドラッグに移ると上がり直すため、メニューの間は今の位置に留める。
    private func holdBarForContextMenu() {
        guard let host, isInputFocused, mediaPicker == nil, !isShowingMediaViewer else { return }
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
        // 投稿の失敗の知らせは、シートを閉じて戻したキーボードが上がりきる前に出ることがあり、その知らせが知らせを出したあとに届く。
        // 知らせを出している間はキーボードが下がるので、バーはキーボードの高さに留めたままにする。
        guard isInputFocused, !isPresentingError else { return }
        keyboardHeightBeforeContextMenu = nil
        releaseHoldAboveKeyboard()
    }

    /// バーの上端から画面の下端までを覆っている。書いていればキーボードも含む。バーが動くたびに測り直す。
    /// 広げている間は、一覧が隠れたままでよいので知らせない。知らせると一覧の下の余白が画面の高さほどに変わり、戻したときに一覧の位置が動きうる。
    private func reportObscuredHeight() {
        guard let host, !isExpanded else { return }
        let height = max(0, host.view.bounds.maxY - bar.frame.minY + barSpacing)
        guard height != obscuredHeight else { return }
        obscuredHeight = height
        onObscuredHeightChange(height)
    }

    /// 書き始めと書き終わりで、バーの中身を入れ替える。高さの変化はキーボードの動きと並べて動かす。
    /// 書き終えたら（投稿したときも）、広げていても5行の上限がある高さに戻し、細いカプセルにする。
    private func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        updateCompletionList()
        let collapses = !editing && isExpanded
        var generation: Int?
        if collapses {
            isExpanded = false
            generation = beginExpansionChange()
        }
        UIView.animate(withDuration: tuning.value(of: TuningCatalog.composeMorphDuration), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            if collapses {
                self.applyExpandedLayout()
            }
            self.applyEditingLayout()
            self.host?.view.layoutIfNeeded()
        } completion: { _ in
            if let generation {
                self.endCollapse(generation: generation)
            }
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
        let showsSpoiler = isEditing && model.showsSpoiler
        setRowHidden(spoilerRow, !showsSpoiler)
        spoilerRow.alpha = showsSpoiler ? 1 : 0
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
            // 投稿して空に戻したときや返信先を替えたときは、補完していた語がなくなる。
            if completionInput === textView {
                completion.textDidChange(nil)
            }
        }
        placeholderLabel.isHidden = !model.text.isEmpty
        if spoilerField.text != model.spoilerText {
            spoilerField.text = model.spoilerText
            if completionInput === spoilerField {
                completion.textDidChange(nil)
            }
        }
        // 返信先を外して引き継いだ注意書きが消えたときなども含め、欄を隠すときは、隠れた欄にキーボードを残さず本文へ移す。
        if !model.showsSpoiler {
            if spoilerField.isFirstResponder {
                textView.becomeFirstResponder()
            }
            if lastFocusedInput === spoilerField {
                lastFocusedInput = textView
            }
        }
        setRowShown(spoilerRow, isEditing && model.showsSpoiler)
        // 添付があると、空の注意書きでも閲覧注意になる。空のまま出している意味が分かるよう、案内を変える。
        spoilerField.placeholder = model.attachments.isEmpty ? "注意書き" : "注意書き（空なら閲覧注意だけ）"
        spoilerClearButton.accessibilityLabel = model.isSensitive ? "注意書きと閲覧注意を外す" : "注意書きを外す"

        let replyAcct = model.replyTo.map { "@\($0.displayed.account.acct)" }
        // 札を消すときは、薄くなる間も文字が残るよう、前の文字のままにする。
        // 返信先から引き継いだ注意書きは、注意書きの欄に見えているので、札には書かない。
        if let replyAcct {
            setReplyTitle("\(replyAcct)への返信")
        }
        setRowShown(replyRow, isEditing && replyAcct != nil)

        attachmentStrip.update(model.attachments.map { attachment in
            ComposeAttachmentStrip.Item(
                attachment: attachment,
                local: model.localMedia[attachment.id],
                status: model.attachmentStatus(of: attachment.id) ?? .uploading,
                isSensitive: model.isSensitive
            )
        })
        mediaViewer?.update(items: viewerItems())
        setRowShown(attachmentStrip, isEditing && !model.attachments.isEmpty)

        let option = VisibilityOption(model.visibility)
        visibilityButton.configuration?.image = UIImage(systemName: option.symbolName)
        visibilityButton.accessibilityLabel = "公開範囲"
        visibilityButton.accessibilityValue = option.title
        visibilityButton.menu = UIMenu(title: "公開範囲", children: visibilityActions())

        updateToolButtons()

        remainingLabel.text = "\(model.remainingCharacters)"
        remainingLabel.textColor = model.remainingCharacters < 0 ? .systemRed : .secondaryLabel
        remainingLabel.accessibilityLabel = "残り\(model.remainingCharacters)文字"
        sendButton.isEnabled = model.canPost
        sendButton.configuration?.showsActivityIndicator = model.isPosting

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
            result.append(NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: UIColor.label, .languageIdentifier: settings.glyphLanguageIdentifier()]))
        }
        return result
    }

    /// メディアを選ぶシートなどを出している間は出さず、閉じたときに知らせる。
    ///
    /// 知らせは表示されると最初の応答者になるため、何もしないとキーボードが下がって投稿欄がカプセルに戻り、書いていたところから直せない。
    /// 添付のビューアと同じく、出す前に自分でキーボードを閉じ、バーをキーボードの高さに留め、閉じたら最後に書いていた入力欄にキーボードを戻す。
    private func presentErrorIfNeeded() {
        guard let message = model.errorMessage, !isPresentingError, let presenter = presenterForErrors, presenter.presentedViewController == nil else { return }
        isPresentingError = true
        logger.info("compose: presenting post error (focused=\(self.isInputFocused) editing=\(self.isEditing) picker=\(self.mediaPicker != nil))")
        if mediaPicker == nil, isInputFocused {
            // ハードウェアキーボードでは、閉じたあとに上がりきった知らせが来ず、留めると外れなくなる。ソフトウェアキーボードが出ているときだけ留める。
            if currentKeyboardHeight > Self.softwareKeyboardMinimumHeight {
                setHoldAboveKeyboard(height: currentKeyboardHeight)
            }
            resignInput()
        }
        let alert = UIAlertController(title: "投稿できませんでした", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            guard let self else { return }
            isPresentingError = false
            model.errorMessage = nil
            guard mediaPicker == nil, isEditing else { return }
            focusLastInput()
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
        if mediaPicker == nil, isInputFocused {
            // ハードウェアキーボードでは、閉じたあとに上がりきった知らせが来ず、留めると外れなくなる。ソフトウェアキーボードが出ているときだけ留める。
            if currentKeyboardHeight > Self.softwareKeyboardMinimumHeight {
                setHoldAboveKeyboard(height: currentKeyboardHeight)
            }
            resignInput()
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
        focusLastInput()
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
    /// 広げている間は、長さに関係なく残りの高さを使い、中でスクロールする。
    private func textDidChange() {
        // 幅が決まる前に測ると1文字ずつ折り返した高さになり、短い文でもスクロールに切り替わってしまう。
        guard textView.bounds.width > 0 else { return }
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        if isCollapsingFromExpanded {
            // 戻す動きの途中でスクロールを止めると、バーが動きを待たずにほぼ戻した高さまで縮んで見えた（スクロールを止めると、UIKitが入力欄の高さを動きの外で決め直すためと見ている）。
            // 動き終わるまではスクロールできるまま、高さの制約で本文に合わせる。
            textHeightLimit.constant = min(fitting, maxTextHeight)
            textHeightLimit.isActive = true
            return
        }
        textHeightLimit.constant = maxTextHeight
        let scrolls = isExpanded || fitting > maxTextHeight
        textHeightLimit.isActive = scrolls && !isExpanded
        if textView.isScrollEnabled != scrolls {
            textView.isScrollEnabled = scrolls
            // スクロールを止めても、入力欄は本来の高さを測り直さない。測り直させないと、5行から4行に減らしたときに入力欄が潰れ、下のボタンの行に重なった。
            textView.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - 補完

    private func installCompletionList(in host: UIViewController) {
        completionList.translatesAutoresizingMaskIntoConstraints = false
        completionList.alpha = 0
        completionList.isHidden = true
        completionList.onSelect = { [weak self] candidate in self?.complete(with: candidate) }
        completionList.onRetry = { [weak self] in self?.completion.retry() }
        // 投稿欄より手前に置く。広げているときは、欄の中の本文に重ねるため。
        host.view.insertSubview(completionList, aboveSubview: bar)
        let height = completionList.heightAnchor.constraint(equalToConstant: 0)
        let aboveBar = completionList.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -completionListSpacing)
        NSLayoutConstraint.activate([
            completionList.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            completionList.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            height,
            aboveBar,
        ])
        completionListHeight = height
        completionListAboveBar = aboveBar
        completionListTop = completionList.topAnchor.constraint(equalTo: host.view.topAnchor)
    }

    private func observeCompletion() {
        withObservationTracking {
            updateCompletionList()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCompletion() }
        }
    }

    /// 違和感レポートに残す、補完の状態。打った語は残さない。
    private var completionContentSummary: String {
        switch completion.content {
        case nil: "nil"
        case .candidates(let candidates): "candidates(\(candidates.count)) selected=\(completion.selectedIndex)"
        case .loading: "loading"
        case .empty: "empty"
        case .failed: "failed"
        case .candidatesWithFailure(let candidates, _): "candidates(\(candidates.count))+failed selected=\(completion.selectedIndex)"
        }
    }

    /// 入力欄のカーソルの位置の語。本文ではメンション、タグ、絵文字を、注意書きでは絵文字だけを補完する。
    /// - Parameter appliesMinimumLength: 候補を出すのに要る文字数を見るか。選んだときに範囲を決め直すだけなら見ない。
    private func completionToken(in input: any UITextInput, appliesMinimumLength: Bool = true) -> CompletionToken? {
        let text = (input as? UITextView)?.text ?? (input as? UITextField)?.text ?? ""
        guard let selection = input.selectedTextRange else { return nil }
        let begin = input.beginningOfDocument
        let start = input.offset(from: begin, to: selection.start)
        let end = input.offset(from: begin, to: selection.end)
        let marked = input.markedTextRange.map { input.offset(from: begin, to: $0.start) ..< input.offset(from: begin, to: $0.end) }
        return CompletionTokenizer.token(
            in: text,
            selection: start ..< max(start, end),
            markedRange: marked,
            kinds: input === textView ? Set(CompletionKind.allCases) : [.emoji],
            minimumQueryLength: appliesMinimumLength ? TuningCatalog.completionMinimumQueryLength(in: tuning) : [:]
        )
    }

    private func completionTextDidChange(in input: any UITextInput) {
        completionInput = input
        completionInputHadMarkedText = input.markedTextRange != nil
        completion.settings = TuningCatalog.completionSettings(in: tuning)
        completion.textDidChange(completionToken(in: input))
    }

    private func completionSelectionDidChange(in input: any UITextInput) {
        guard completionInput === input else { return }
        // 変換を確定しただけでは本文が変わったことにならないことがあるため、確定したらここで語を読み直す。
        if completionInputHadMarkedText, input.markedTextRange == nil {
            completionTextDidChange(in: input)
            return
        }
        completion.selectionDidChange(completionToken(in: input))
    }

    /// 入力欄の編集が終わったら閉じる。メディアを選ぶシートやビューアを出すためにキーボードを閉じたときも閉じ、戻ったら打ち直すまで出さない。
    private func endCompletion(in input: any UITextInput) {
        guard completionInput === input else { return }
        completion.textDidChange(nil)
        completionInput = nil
    }

    /// 候補を本文に入れる。日本語の直後なら前に空白を、後ろに空白がなければ後ろにも空白を入れる。
    /// 入力欄の`replace`で入れ、取り消し（シェイクや⌘Z）で戻せるようにする。
    private func complete(with candidate: CompletionCandidate) {
        guard let input = completionInput, let shown = completion.token, !model.isPosting else { return }
        // 候補を出したあとにカーソルだけを語の中で動かしていれば、置き換える範囲はいまのカーソルで決め直す。
        // ハッシュタグはカーソルより後ろを語に含めないため、出したときの範囲のままだと後ろの文まで消してしまう。
        let current = completionToken(in: input, appliesMinimumLength: false)
        let token = current.flatMap { $0.kind == shown.kind && $0.range.lowerBound == shown.range.lowerBound ? $0 : nil } ?? shown
        let text = (input as? UITextView)?.text ?? (input as? UITextField)?.text ?? ""
        let insertion = CompletionTokenizer.insertion(of: candidate.completion, replacing: token, in: text)
        let begin = input.beginningOfDocument
        guard let start = input.position(from: begin, offset: insertion.range.lowerBound),
              let end = input.position(from: begin, offset: insertion.range.upperBound),
              let range = input.textRange(from: start, to: end)
        else { return }
        logger.info("completion: selected \(token.kind.rawValue, privacy: .public) leadingSpace=\(token.needsLeadingSpace)")
        input.replace(range, withText: insertion.text)
        if let cursor = input.position(from: begin, offset: insertion.cursor) {
            input.selectedTextRange = input.textRange(from: cursor, to: cursor)
        }
        // 入力欄の知らせが来なくても、下書きを入力欄に合わせる。
        if input === textView {
            model.text = textView.text
            textDidChange()
        } else if input === spoilerField {
            model.spoilerText = spoilerField.text ?? ""
        }
        completion.didComplete()
    }

    private func completionKeys() -> CompletionKeys {
        CompletionKeys(
            hasCandidate: { [weak self] in self?.isCompletionListShown == true && self?.completion.selectedCandidate != nil },
            isShown: { [weak self] in self?.isCompletionListShown == true },
            // ↑↓は見た目の向きに動かす。下から積んでいるときは、↑で優先度の低い候補へ移る。
            move: { [weak self] offset in
                guard let self else { return }
                completion.moveSelection(by: completionList.growsUpward ? -offset : offset)
            },
            confirm: { [weak self] in
                guard let self, let candidate = completion.selectedCandidate else { return }
                complete(with: candidate)
            },
            dismiss: { [weak self] in self?.completion.dismiss() }
        )
    }

    /// 補完の状態を一覧に映す。書いていて、補完している入力欄がキーボードを出しているときだけ出す。
    private func updateCompletionList() {
        let content = completion.content
        if let content, let kind = completion.token?.kind {
            completionList.update(content, kind: kind, selectedIndex: completion.selectedIndex)
        }
        let shows = content != nil && isEditing && (completionInput as? UIResponder)?.isFirstResponder == true
        if shows {
            layoutCompletionList()
        }
        setCompletionListShown(shows)
    }

    private func layoutCompletionListIfShown() {
        guard isCompletionListShown else { return }
        layoutCompletionList()
    }

    /// 広げていなければ欄の上に、広げていれば打っている行のすぐ下（入りきらなければ行の上）に置く。
    /// 入りきらない高さは、一覧の中でスクロールする。
    private func layoutCompletionList() {
        guard let host, let completionListHeight, let completionListAboveBar, let completionListTop else { return }
        let wanted = completionList.contentHeight
        var height: CGFloat
        if isExpanded, let caret = completionCaretRect(in: host.view) {
            let lower = tools.convert(tools.bounds, to: host.view).minY - completionListSpacing
            let upper = bar.frame.minY + completionListSpacing
            let below = lower - (caret.maxY + completionListSpacing)
            let above = caret.minY - completionListSpacing - upper
            let top: CGFloat
            // 下に全部入れば下、入らず上なら入るなら上、どちらにも入らなければ広い方に出して中でスクロールする。
            if below >= wanted || (above < wanted && below >= above) {
                height = min(wanted, max(below, 0))
                top = caret.maxY + completionListSpacing
                completionList.growsUpward = false
            } else {
                height = min(wanted, max(above, 0))
                top = caret.minY - completionListSpacing - height
                completionList.growsUpward = true
            }
            setConstant(completionListTop, top)
            completionListAboveBar.isActive = false
            completionListTop.isActive = true
        } else {
            let safeTop = host.view.safeAreaLayoutGuide.layoutFrame.minY
            let available = bar.frame.minY - completionListSpacing * 2 - safeTop
            height = min(wanted, max(available, min(wanted, ComposeCompletionList.rowHeight * 2)))
            completionList.growsUpward = true
            completionListTop.isActive = false
            completionListAboveBar.isActive = true
        }
        setConstant(completionListHeight, height)
    }

    /// 同じ値を入れ直すと、欄が動くたびに測り直しが続くので、変わったときだけ入れる。
    private func setConstant(_ constraint: NSLayoutConstraint, _ value: CGFloat) {
        guard abs(constraint.constant - value) > 0.5 else { return }
        constraint.constant = value
    }

    /// 打っている行の、`view`の座標での位置。
    private func completionCaretRect(in view: UIView) -> CGRect? {
        guard let input = completionInput as? any UIView & UITextInput, let selection = input.selectedTextRange else { return nil }
        let caret = input.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return nil }
        return input.convert(caret, to: view)
    }

    /// 出し入れは薄くするだけにする。動きの途中でも、一覧を押せるようにする。
    private func setCompletionListShown(_ shown: Bool) {
        guard shown != isCompletionListShown else { return }
        isCompletionListShown = shown
        let duration = tuning.value(of: TuningCatalog.completionFadeDuration)
        if shown {
            completionList.isHidden = false
            host?.view.layoutIfNeeded()
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.completionList.alpha = shown ? 1 : 0
        } completion: { _ in
            guard !self.isCompletionListShown else { return }
            self.completionList.isHidden = true
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

    /// 注意書きの行。印、入力欄、外すボタンを並べ、下に線を引いて本文と分ける。
    private func makeSpoilerRow() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false

        spoilerField.font = .preferredFont(forTextStyle: .body)
        spoilerField.adjustsFontForContentSizeCategory = true
        // 本文と同じく、自分の文で言語が分からないため、設定の字形で描く。
        spoilerField.followGlyphLanguage(of: settings)
        spoilerField.placeholder = "注意書き"
        spoilerField.accessibilityLabel = "注意書き"
        spoilerField.returnKeyType = .next
        spoilerField.delegate = self
        spoilerField.onSubmit = { [weak self] in self?.submit() }
        spoilerField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            model.spoilerText = spoilerField.text ?? ""
            completionTextDidChange(in: spoilerField)
        }, for: .editingChanged)
        spoilerField.completionKeys = completionKeys()

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        let clear = spoilerClearButton
        clear.configuration = configuration
        clear.addAction(UIAction { [weak self] _ in self?.setSpoilerShown(false) }, for: .primaryActionTriggered)
        clear.setContentHuggingPriority(.required, for: .horizontal)
        clear.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = UIStackView(arrangedSubviews: [icon, spoilerField, clear])
        content.alignment = .center
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let row = UIView()
        row.addSubview(content)
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
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
        textView.completionKeys = completionKeys()
        textView.accessibilityLabel = "本文"
        // 広げたときに、残りの高さを本文が使う。行が収まらない高さでは、本文から縮める。
        textView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)
        // 書いている文字は自分の文で言語が分からないため、設定の字形で描く。
        textView.followGlyphLanguage(of: settings)

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
        expandButton.configuration?.baseForegroundColor = .label

        remainingLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.accessibilityLabel = "投稿"
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addButton.configuration?.image = UIImage(systemName: "plus")
        addButton.configuration?.baseForegroundColor = .label
        addButton.accessibilityLabel = "追加"
        addButton.showsMenuAsPrimaryAction = true
        // 開くたびに項目を作り直し、添付できるかやシートを出しているかを、その時点の状態で出す。
        addButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.addMenuElements() ?? [])
        }])
        tools.onLayout = { [weak self] in self?.placeToolsAfterLayout() }
        // 公開範囲、展開、添付などの項目のボタンと＋は、設定の並びに合わせて`arrangeToolButtons`が前に置く。
        for view in [spacer, remainingLabel, sendButton] {
            tools.addArrangedSubview(view)
        }
        tools.alignment = .center
        tools.spacing = 4
        attachmentStrip.onSelect = { [weak self] id in self?.openAttachment(id) }
        attachmentStrip.onMove = { [weak self] id, index in self?.model.moveAttachment(id, to: index) }
        attachmentStrip.onRemove = { [weak self] id in self?.removeAttachment(id) }
        attachmentStrip.onContextMenuWillShow = { [weak self] in self?.holdBarForContextMenu() }
        attachmentStrip.onContextMenuWillEnd = { [weak self] in self?.contextMenuWillEnd() }
        for view in [restRow, replyRow, spoilerRow, attachmentStrip, textView, tools] {
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
        // 広げている間に本文をスクロールしたら、打っている行に付けた一覧も動かす。
        if scrollView === textView {
            layoutCompletionListIfShown()
            return
        }
        guard scrollView === dragArea, scrollView.contentOffset != .zero else { return }
        scrollView.contentOffset = .zero
    }

    func textViewDidChange(_ textView: UITextView) {
        model.text = textView.text
        textDidChange()
        completionTextDidChange(in: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        completionSelectionDidChange(in: textView)
    }

    /// 送っている間は、送っている下書きと食い違わないよう打った文字を受け付けない。
    /// 入力欄を止める（`isEditable`を外す）とキーボードが外れて書き終えたことになり、失敗したときに書いていたところへ戻れないため、フォーカスは残す。
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        !model.isPosting
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        inputWillBeginEditing(from: spoilerField)
        return true
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        inputDidBeginEditing(textView)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        endCompletion(in: textView)
        inputDidEndEditing()
    }

    /// 入力欄がキーボードを出す前に呼ぶ。UIKitは、次の入力欄に出してよいかを聞いてから、前の入力欄の編集を終える。
    /// 前の入力欄がキーボードを出していれば、フォーカスを移す途中として、前の入力欄の編集が終わっても書き終えたことにしない。
    private func inputWillBeginEditing(from other: UIResponder) {
        if other.isFirstResponder {
            isMovingFocus = true
        }
    }

    /// シートを出している間に入力欄に触れたら、シートを閉じてキーボードに戻る。
    private func inputDidBeginEditing(_ input: UIView) {
        isMovingFocus = false
        lastFocusedInput = input
        if let completionInput, completionInput !== input {
            completion.textDidChange(nil)
            self.completionInput = nil
        }
        guard let mediaPicker, !mediaPicker.isClosing else { return }
        logger.info("media picker: closing because an input began editing")
        mediaPicker.close(notifiesWillClose: false)
    }

    private func inputDidEndEditing() {
        // 本文と注意書きの間でフォーカスを移しているときは、書いている状態のままにする。
        // メディアを選ぶシートを出すためにキーボードを閉じたときも同じ。
        // 添付のビューアや、投稿の失敗の知らせを開くためにキーボードを閉じたときも同じ。閉じ終わったら入力欄にキーボードを戻す。
        // シートを閉じたあとに書き終えたときは、キーボードが上がりきった知らせが来ずにバーを留めたままでも、カプセルに戻す。
        guard !isMovingFocus, mediaPicker == nil, !isShowingMediaViewer, !isShowingToolLayoutSettings, !isPresentingError else { return }
        releaseHoldAboveKeyboard()
        setEditing(false)
        onEndEditing()
    }
}

extension InlineComposeController: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        inputWillBeginEditing(from: textView)
        return true
    }

    /// 本文と同じく、送っている間はフォーカスを残したまま、打った文字を受け付けない。
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        !model.isPosting
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        inputDidBeginEditing(textField)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        endCompletion(in: textField)
        inputDidEndEditing()
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        completionSelectionDidChange(in: textField)
    }

    /// 注意書きを書き終えたら、Returnで本文へ移る。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textView.becomeFirstResponder()
        return false
    }
}

/// Returnは改行と変換の確定に使うため、送信はボタンと、ハードウェアキーボードの⌘Returnだけにする。
/// 補完の候補を出している間だけ、Tab・Returnで確定、↑↓で選ぶ候補を移し、Escで閉じる（web UIと同じ）。
private final class ComposeTextView: GlyphLanguageTextView {
    var onSubmit: () -> Void = {}
    var completionKeys = CompletionKeys()

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(title: "投稿", action: #selector(submitFromKeyboard), input: "\r", modifierFlags: .command)
        return (super.keyCommands ?? []) + [submit] + completionKeys.commands(
            move: #selector(moveCompletion(_:)), confirm: #selector(confirmCompletion), dismiss: #selector(dismissCompletion)
        )
    }

    @objc private func submitFromKeyboard() {
        onSubmit()
    }

    @objc private func moveCompletion(_ command: UIKeyCommand) {
        completionKeys.move(command.input == UIKeyCommand.inputUpArrow ? -1 : 1)
    }

    @objc private func confirmCompletion() {
        completionKeys.confirm()
    }

    @objc private func dismissCompletion() {
        completionKeys.dismiss()
    }
}

/// 投稿欄のボタンの行。並べ直すたびに知らせ、行に入りきらない部品のボタンを＋へ回せるようにする。
private final class ComposeToolsView: UIStackView {
    var onLayout: () -> Void = {}

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
    }
}

/// 注意書きの入力欄。本文と同じく、ハードウェアキーボードの⌘Returnで送信し、補完の候補を出している間はキーで選べる。
private final class ComposeSpoilerField: GlyphLanguageTextField {
    var onSubmit: () -> Void = {}
    var completionKeys = CompletionKeys()

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(title: "投稿", action: #selector(submitFromKeyboard), input: "\r", modifierFlags: .command)
        return (super.keyCommands ?? []) + [submit] + completionKeys.commands(
            move: #selector(moveCompletion(_:)), confirm: #selector(confirmCompletion), dismiss: #selector(dismissCompletion)
        )
    }

    @objc private func submitFromKeyboard() {
        onSubmit()
    }

    @objc private func moveCompletion(_ command: UIKeyCommand) {
        completionKeys.move(command.input == UIKeyCommand.inputUpArrow ? -1 : 1)
    }

    @objc private func confirmCompletion() {
        completionKeys.confirm()
    }

    @objc private func dismissCompletion() {
        completionKeys.dismiss()
    }
}

/// 補完の候補を出している間の、ハードウェアキーボードの操作。
@MainActor
struct CompletionKeys {
    /// 確定できる候補を出している。
    var hasCandidate: () -> Bool = { false }
    /// 一覧を出している（候補がなくても、読み込み中や失敗の行を出している）。
    var isShown: () -> Bool = { false }
    var move: (Int) -> Void = { _ in }
    var confirm: () -> Void = {}
    var dismiss: () -> Void = {}

    /// 出している間だけ返す。出していないときは、↑↓・Tab・Return・Escはふだんどおり入力欄が受ける。
    func commands(move: Selector, confirm: Selector, dismiss: Selector) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        if hasCandidate() {
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: move),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: move),
                UIKeyCommand(input: "\t", modifierFlags: [], action: confirm),
                UIKeyCommand(input: "\r", modifierFlags: [], action: confirm),
            ]
        }
        if isShown() {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: dismiss))
        }
        // 矢印やTab、Returnは、入力欄の移動や改行より先に受ける。
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
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

