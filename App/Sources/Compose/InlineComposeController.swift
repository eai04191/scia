import Observation
import SciaCore
import UIKit

/// タブバーの上に常に出しておく投稿欄。タイムラインを見たまま短い投稿や返信を書けるようにする。
///
/// タブバーのアクセサリーはキーボードを出しても画面の下端に残り、キーボードに隠れる。
/// そのため、アクセサリーは下書きを見せてタップを受けるだけにし、書くときはキーボードの上に付いて動くバーに切り替える。
@MainActor
final class InlineComposeController: NSObject {
    let model: ComposeModel
    private(set) lazy var accessory = UITabAccessory(contentView: makeAccessoryContent())
    /// 編集を始めるときに呼ぶ。既定の公開範囲などをまだ読めていなければ読む。
    var onBeginEditing: () -> Void = {}
    /// 全画面の投稿画面に広げる。
    var onExpand: () -> Void = {}
    /// 返信先の札を押したときに呼ぶ。返信先の投稿を見せる。
    var onShowReplyTarget: (Status) -> Void = { _ in }
    /// 投稿できたあとに呼ぶ。
    var onPosted: () -> Void = {}
    /// 画面の下端から、キーボードと編集用のバーが覆っている高さが変わったときに呼ぶ。書いていないときは0。
    var onObscuredHeightChange: (CGFloat) -> Void = { _ in }

    private weak var host: UIViewController?
    private let accessoryLabel = UILabel()
    private let bar = UIVisualEffectView(effect: UIGlassEffect())
    private lazy var replyButton = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
        guard let target = self?.model.replyTo else { return }
        self?.onShowReplyTarget(target)
    })
    private lazy var replyRow = makeReplyRow()
    private let textView = ComposeTextView()
    private let placeholderLabel = UILabel()
    private lazy var textHeightLimit = textView.heightAnchor.constraint(equalToConstant: maxTextHeight)
    private let visibilityButton = UIButton(configuration: .plain())
    private let remainingLabel = UILabel()
    private lazy var sendButton = UIButton(configuration: .filled(), primaryAction: UIAction { [weak self] _ in self?.submit() })
    private var isPresentingError = false
    /// 編集用のバーとキーボードの間の余白。
    private let barSpacing: CGFloat = 8
    /// 画面の下端からキーボードの上端までの高さ。キーボードが出ていなければ0。
    private var keyboardHeight: CGFloat = 0
    private var obscuredHeight: CGFloat = 0
    private var keyboardObserver: (any NSObjectProtocol)?
    /// 入力バーの中身を載せるスクロールビュー。バーを下へ引くと、キーボードが指に付いて下がる。
    private let dragArea = KeyboardDragArea()

    /// 入力欄がこれより高くなったら、伸ばさずに中でスクロールする。
    private var maxTextHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight * 5 + textView.textContainerInset.top + textView.textContainerInset.bottom
    }

    init(model: ComposeModel) {
        self.model = model
        super.init()
        model.onPosted = { [weak self] in
            self?.textView.resignFirstResponder()
            self?.onPosted()
        }
    }

    /// キーボードの上に付いて動く編集用のバーを、`host`の画面に置く。
    func install(in host: UIViewController) {
        self.host = host
        configureBar()
        host.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: host.view.keyboardLayoutGuide.topAnchor, constant: -barSpacing),
        ])
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
            let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 0
            MainActor.assumeIsolated {
                self?.keyboardWillChange(to: frame, duration: duration, curve: curve)
            }
        }
        observeModel()
    }

    isolated deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

    /// 編集用のバーを出して、キーボードを出す。
    func beginEditing() {
        onBeginEditing()
        bar.isHidden = false
        host?.view.bringSubviewToFront(bar)
        // 隠している間に下書きが変わっていても、出す前に高さを合わせる。
        bar.layoutIfNeeded()
        textDidChange()
        UIView.animate(withDuration: 0.2) { self.bar.alpha = 1 }
        textView.becomeFirstResponder()
    }

    /// 返信先を付けて書き始める。
    func reply(to status: Status) {
        model.setReplyTarget(status)
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

    /// キーボードと同じ動きで、覆う高さを知らせる。タイムラインの下側の余白がキーボードと揃って動く。
    private func keyboardWillChange(to frame: CGRect?, duration: Double, curve: Int) {
        guard let host, let frame, let screen = host.view.window?.screen else { return }
        let keyboardTop = host.view.convert(frame, from: screen.coordinateSpace).minY
        keyboardHeight = max(0, host.view.bounds.maxY - keyboardTop)
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: UInt(curve) << 16)) {
            self.reportObscuredHeight()
        }
    }

    /// 書いている間は、キーボードに編集用のバーを足した高さを覆っている。入力が伸びたときや返信先の札が出たときも測り直す。
    private func reportObscuredHeight() {
        let height = keyboardHeight > 0 && textView.isFirstResponder ? keyboardHeight + barSpacing + bar.bounds.height : 0
        guard height != obscuredHeight else { return }
        obscuredHeight = height
        onObscuredHeightChange(height)
    }

    private func endEditing() {
        UIView.animate(withDuration: 0.2) {
            self.bar.alpha = 0
        } completion: { _ in
            // 閉じるアニメーションの途中でまた書き始めていたら、隠さない。
            if !self.textView.isFirstResponder {
                self.bar.isHidden = true
            }
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
        replyRow.isHidden = replyAcct == nil
        replyButton.configuration?.title = replyAcct.map { "\($0)への返信" + (model.showsSpoiler ? "（注意書き付き）" : "") }

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

        accessoryLabel.attributedText = accessoryText(replyAcct: replyAcct)
        presentErrorIfNeeded()
        bar.layoutIfNeeded()
        reportObscuredHeight()
    }

    /// アクセサリーに出す下書きの1行。返信なら宛先を札にまとめ、自分で書いた部分だけを続ける。何も書いていなければ書き出しを促す。
    private func accessoryText(replyAcct: String?) -> NSAttributedString {
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

    private func makeAccessoryContent() -> UIView {
        let content = UIControl()
        accessoryLabel.lineBreakMode = .byTruncatingTail
        accessoryLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(accessoryLabel)
        NSLayoutConstraint.activate([
            accessoryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            accessoryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            accessoryLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        content.addAction(UIAction { [weak self] _ in self?.beginEditing() }, for: .touchUpInside)
        content.isAccessibilityElement = true
        content.accessibilityLabel = "投稿欄"
        content.accessibilityTraits = .button
        return content
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
        replyButton.configuration?.contentInsets = .zero
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
        let row = UIStackView(arrangedSubviews: [replyButton, clear])
        row.spacing = 6
        return row
    }

    private func configureBar() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.cornerConfiguration = .corners(radius: .fixed(24))
        bar.isHidden = true
        bar.alpha = 0
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
        let tools = UIStackView(arrangedSubviews: [visibilityButton, expandButton, spacer, remainingLabel, sendButton])
        tools.alignment = .center
        tools.spacing = 4
        let stack = UIStackView(arrangedSubviews: [replyRow, textView, tools])
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
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
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
        endEditing()
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
