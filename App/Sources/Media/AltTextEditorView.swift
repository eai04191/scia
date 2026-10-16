import SciaCore
import UIKit

/// ビューアの下に出す、代替テキストを書く複数行の入力欄。キーボードのすぐ上に付ける。
///
/// 右端のボタンを押すか、画像を下へスワイプするか、左右のページへ切り替えると、キーボードを下げて書き終える。
final class AltTextEditorView: UIView {
    /// 書き終えた。キーボードを下げたときに呼ぶ。
    var onEnd: (String) -> Void = { _ in }
    /// 書き終えるボタンを押した。
    var onDone: () -> Void = {}
    /// 文字数の上限。上限に近づいたら残りの文字数を出す。
    var limit = 1500 {
        didSet { updateRemaining() }
    }

    /// 残りの文字数がこれ以下になったら、残りを出す。
    var remainingThreshold = Int(TuningCatalog.mediaDescriptionRemainingThreshold.defaultValue) {
        didSet { updateRemaining() }
    }
    /// 書いた分だけ伸ばす最大の行数。超えたら伸ばさずに中でスクロールする。
    var maxLines = Int(TuningCatalog.mediaDescriptionMaxLines.defaultValue) {
        didSet { updateTextHeight() }
    }

    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let remainingLabel = UILabel()
    /// 書き終えるボタン。「完了」と書くとビューアを閉じるボタンに見えるため、キーボードを下げる絵にする。
    let doneButton = UIButton(configuration: .plain())
    private lazy var textHeight = textView.heightAnchor.constraint(equalToConstant: 0)
    /// ボタンの絵の中心を、入力欄の最後の行の中心にそろえる。文字の大きさで行の高さが変わるため、並べ直すたびに合わせる。
    private lazy var doneButtonCenter = doneButton.centerYAnchor.constraint(equalTo: textView.bottomAnchor)

    /// 入力欄がこれより高くなったら、伸ばさずに中でスクロールする。
    private var maxTextHeight: CGFloat {
        (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight * CGFloat(maxLines) + textView.textContainerInset.top + textView.textContainerInset.bottom
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.keyboardAppearance = .dark
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = "代替テキスト"
        textView.delegate = self
        placeholderLabel.text = "代替テキストを追加"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        placeholderLabel.isAccessibilityElement = false
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        remainingLabel.textAlignment = .right
        doneButton.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
        doneButton.configuration?.baseForegroundColor = .white
        doneButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        doneButton.accessibilityLabel = "代替テキストを書き終える"
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [textView, remainingLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(doneButton)
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -4),
            // 書いた分だけ入力欄が伸びても、ボタンは最後の行の横に残す。
            doneButton.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            doneButtonCenter,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
            textHeight,
        ])
        updateRemaining()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textDidChange()
        }
    }

    /// 書いている。
    var isEditing: Bool { textView.isFirstResponder }

    func beginEditing() {
        textView.becomeFirstResponder()
    }

    /// キーボードを下げて書き終える。書き終えたことは`onEnd`で知らせる。
    func endEditing() {
        textView.resignFirstResponder()
    }

    override func layoutSubviews() {
        let lineHeight = (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        doneButtonCenter.constant = -(textView.textContainerInset.bottom + lineHeight / 2)
        super.layoutSubviews()
        // 入力欄の幅は、入れたスタックが並べ直したときに決まる。幅が決まる前に文字を入れられていても測れるよう、先に並べさせる。
        textView.superview?.layoutIfNeeded()
        updateTextHeight()
    }

    private func textDidChange() {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateRemaining()
        updateTextHeight()
    }

    /// 書いた分だけ伸ばし、決めた高さを超えたら中でスクロールする。
    private func updateTextHeight() {
        // 幅が決まる前に測ると1文字ずつ折り返した高さになるため、決まってから測る。
        guard textView.bounds.width > 0 else { return }
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(fitting, maxTextHeight)
        guard textHeight.constant != height else { return }
        textHeight.constant = height
    }

    /// Mastodonは代替テキストの長さをRubyの文字列の長さ（Unicodeのコードポイントの数）で数えるため、同じ数え方にする。
    private var remaining: Int {
        limit - textView.text.unicodeScalars.count
    }

    private func updateRemaining() {
        let remaining = remaining
        remainingLabel.isHidden = remaining > remainingThreshold
        remainingLabel.text = "\(remaining)"
        remainingLabel.textColor = remaining < 0 ? .systemRed : UIColor.white.withAlphaComponent(0.7)
        remainingLabel.accessibilityLabel = "残り\(remaining)文字"
    }
}

extension AltTextEditorView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onEnd(textView.text)
    }
}
