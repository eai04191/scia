import SciaCore
import UIKit

/// 投稿欄の投票の欄。本文の下に、選択肢の入力欄と、設定の1行を並べる。決まりは`docs/poll.md`の「投票を作る」。
///
/// 選択肢の欄は、一覧の投票と同じく角丸のボックスに入れ、書くとどう見えるかを分かるようにする。欄の数は下書きが決め、最後の欄に書くと空の欄が増える。
/// 空の欄は送らないので、選択肢を足すボタンも消すボタンも置かない。
/// 設定（締め切り、選び方、結果を見せるか）は、今どうなっているかが見え、1回押せば変えられるよう、ボタンを1行に並べる。
/// 1つのメニューにまとめても設定の行は残り、押す回数が増えるだけだったため。
/// どのボタンもラベルに今の設定を出す。締め切りが「7日」と今の値を出す横で、切り替えだけ機能の名前を出すと、オフの「複数選択」を今の設定と読み違えるため。
///
/// 入力欄のフォーカスと補完は投稿欄が本文や注意書きと一緒に扱うため、入力欄の`delegate`と打ったときの処理は置く側が決める。
@MainActor
final class ComposePollEditor: UIView {
    struct Content: Equatable {
        var poll: PollDraft
        /// 選べる締め切り。
        var expiryChoices: [Int]
    }

    /// 入力欄を作ったときに呼ぶ。`delegate`や打ったときの処理を付ける。
    var onMakeField: (ComposeLineField) -> Void = { _ in }
    var onSetExpiry: (Int) -> Void = { _ in }
    var onSetMultiple: (Bool) -> Void = { _ in }
    var onSetHidesTotals: (Bool) -> Void = { _ in }
    var onRemovePoll: () -> Void = {}

    /// 選択肢の入力欄。並びの順。
    private(set) var fields: [ComposeLineField] = []
    private var optionRows: [OptionRow] = []
    private let optionsStack = UIStackView()
    private let expiryButton = UIButton(configuration: .gray())
    private let multipleButton = UIButton(configuration: .gray())
    private let hidesTotalsButton = UIButton(configuration: .gray())
    /// 切り替えのボタンの幅を、どちらの値でも同じにする制約。文字の大きさが変わったら測り直す。
    private lazy var multipleWidth = Self.minimumWidth(of: multipleButton)
    private lazy var hidesTotalsWidth = Self.minimumWidth(of: hidesTotalsButton)
    private let removeButton = UIButton(configuration: .plain())
    private(set) var content: Content?
    /// 増えて、まだ浮かび上がらせていない欄。
    private var appearingRows: [UIView] = []
    /// 減って並びから外し、まだ薄くし始めていない欄。
    private var leavingRows: [UIView] = []

    /// 選択肢の1行。角丸のボックスに、選び方のマークと入力欄を並べる。
    private struct OptionRow {
        let view: UIView
        let indicator: UIImageView
        let field: ComposeLineField
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        optionsStack.spacing = 6
        // 欄が増減するとき、増えた欄や薄くしている欄が、伸び縮みする途中の欄の外へ出て、設定の行に重ならないよう切り抜く。
        // 欄の中身は角丸のボックスの内側に収まり、外へ描くものはない。
        optionsStack.clipsToBounds = true

        for button in [expiryButton, multipleButton, hidesTotalsButton] {
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.imagePadding = 4
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .footnote)
                return attributes
            }
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
            configuration.titleLineBreakMode = .byTruncatingTail
            button.configuration = configuration
            button.setContentHuggingPriority(.required, for: .horizontal)
            // 幅が足りなければ、設定の文字を切り、外すボタンは縮めない。
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        expiryButton.configuration?.image = UIImage(systemName: "clock")
        // 締め切りは「1日」のように短く、切ると値が読めなくなるため、幅が足りなければ先に切り替えのボタンの文字を切る。
        // 切り替えのボタンの幅を揃える下限より強くする。iPhone SEの幅で、締め切りが「…」だけになったため。
        expiryButton.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        expiryButton.showsMenuAsPrimaryAction = true
        expiryButton.accessibilityLabel = "締め切り"
        multipleButton.accessibilityLabel = "選び方"
        multipleButton.addAction(UIAction { [weak self] _ in
            guard let poll = self?.content?.poll else { return }
            self?.onSetMultiple(!poll.multiple)
        }, for: .primaryActionTriggered)
        hidesTotalsButton.accessibilityLabel = "結果"
        hidesTotalsButton.addAction(UIAction { [weak self] _ in
            guard let poll = self?.content?.poll else { return }
            self?.onSetHidesTotals(!poll.hidesTotals)
        }, for: .primaryActionTriggered)

        var remove = UIButton.Configuration.plain()
        remove.image = UIImage(systemName: "xmark.circle.fill")
        remove.baseForegroundColor = .secondaryLabel
        remove.contentInsets = .zero
        removeButton.configuration = remove
        removeButton.accessibilityLabel = "投票を外す"
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemovePoll() }, for: .primaryActionTriggered)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settingsRow = UIStackView(arrangedSubviews: [expiryButton, multipleButton, hidesTotalsButton, spacer, removeButton])
        settingsRow.alignment = .center
        settingsRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [optionsStack, settingsRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 下書きに合わせる。`animatesRows`なら、欄の増減をすぐには見せず、置く側が投稿欄の高さを変える動きの中で`revealRowChanges`を、
    /// 動き終えたら`finishRowChanges`を呼ぶ。増えた欄は、置かれる場所で透明にしておき、浮かび上がらせる。減った欄は、並びから外して元の場所に残し、薄くしてから外す。
    /// 欄の数が変わったらtrueを返す。
    @discardableResult
    func apply(_ content: Content, animatesRows: Bool = false) -> Bool {
        self.content = content
        let poll = content.poll
        let rowCount = optionRows.count
        while optionRows.count < poll.options.count {
            let row = makeOptionRow(index: optionRows.count)
            let previous = optionRows.last?.view.frame
            optionRows.append(row)
            fields.append(row.field)
            optionsStack.addArrangedSubview(row.view)
            if animatesRows, let previous {
                // 並べ直しを動きの中で行うと、作ったばかりの欄は大きさ0から広がるため、並ぶ場所に先に置く。
                UIView.performWithoutAnimation {
                    row.view.frame = previous.offsetBy(dx: 0, dy: previous.height + optionsStack.spacing)
                    row.view.layoutIfNeeded()
                }
                row.view.alpha = 0
                appearingRows.append(row.view)
            }
        }
        while optionRows.count > poll.options.count, let row = optionRows.popLast() {
            fields.removeLast()
            if animatesRows {
                // 並びから外すと位置を決める制約もなくなり、薄くする途中に縮みながら動くため、今の位置に留める。
                let frame = row.view.frame
                optionsStack.removeArrangedSubview(row.view)
                row.view.translatesAutoresizingMaskIntoConstraints = true
                row.view.frame = frame
                row.view.isUserInteractionEnabled = false
                leavingRows.append(row.view)
            } else {
                row.view.removeFromSuperview()
            }
        }
        let indicator = UIImage(systemName: poll.multiple ? "square" : "circle")
        for (index, row) in optionRows.enumerated() {
            // 打っている欄に同じ値を入れ直すと、カーソルや変換中の文字が飛ぶため、違うときだけ入れる。
            if row.field.text != poll.options[index] {
                row.field.text = poll.options[index]
            }
            row.indicator.image = indicator
        }

        let expiry = PollDraft.expiryTitle(poll.expiresIn)
        expiryButton.configuration?.title = expiry
        expiryButton.accessibilityValue = expiry
        expiryButton.menu = UIMenu(title: "締め切り", children: content.expiryChoices.map { seconds in
            UIAction(title: PollDraft.expiryTitle(seconds), state: seconds == poll.expiresIn ? .on : .off) { [weak self] _ in
                self?.onSetExpiry(seconds)
            }
        })
        // チェックが1つだけのアイコンと、2つとも付いたアイコンで、1つだけ選べるか、いくつも選べるかを表す。
        Self.setValue(multipleButton, title: poll.multiple ? "複数選ぶ" : "1つ選ぶ", symbolName: poll.multiple ? "checklist.checked" : "checklist")
        Self.setValue(hidesTotalsButton, title: poll.hidesTotals ? "結果を隠す" : "結果を見せる", symbolName: poll.hidesTotals ? "eye.slash" : "eye")
        // 押すとラベルの長さが変わり、右隣のボタンがずれるため、2つの値の長いほうに幅を合わせる。
        multipleWidth.constant = Self.widestFit(of: multipleButton, values: [("1つ選ぶ", "checklist"), ("複数選ぶ", "checklist.checked")])
        hidesTotalsWidth.constant = Self.widestFit(of: hidesTotalsButton, values: [("結果を見せる", "eye"), ("結果を隠す", "eye.slash")])
        hidesTotalsButton.accessibilityHint = poll.hidesTotals ? "締め切るまで票数を見せません。押すと、投票した人に票数を見せます" : "投票した人に票数を見せます。押すと、締め切るまで隠します"
        return optionRows.count != rowCount
    }

    /// 増えた欄を浮かび上がらせ、減った欄を薄くする。投稿欄の高さを変える動きの中で呼び、返した欄を、動き終えたら`finishRowChanges`に渡す。
    func revealRowChanges() -> [UIView] {
        appearingRows.forEach { $0.alpha = 1 }
        appearingRows = []
        let leaving = leavingRows
        leaving.forEach { $0.alpha = 0 }
        leavingRows = []
        return leaving
    }

    /// 薄くし終えた欄を外す。
    func finishRowChanges(_ leaving: [UIView]) {
        leaving.forEach { $0.removeFromSuperview() }
    }

    private static func minimumWidth(of button: UIButton) -> NSLayoutConstraint {
        let constraint = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        // 幅が足りないときは、ボタンの文字を切って収めるため、必須にしない。
        constraint.priority = .defaultHigh
        constraint.isActive = true
        // 中身にぴったり縮もうとする優先度が必須のままだと、この下限が負けるため、下限より下げる。余った幅は、間の空きが受け持つ。
        button.setContentHuggingPriority(.defaultHigh - 1, for: .horizontal)
        return constraint
    }

    /// `values`のどれをラベルにしても収まる幅。ボタンの見た目の設定は描くときに当たり、その場で替えても大きさに出ないため、同じ設定の別のボタンで測る。
    private static func widestFit(of button: UIButton, values: [(title: String, symbolName: String)]) -> CGFloat {
        values.map { value in
            var configuration = button.configuration
            configuration?.title = value.title
            configuration?.image = UIImage(systemName: value.symbolName)
            let probe = UIButton(configuration: configuration ?? .gray())
            probe.traitOverrides.preferredContentSizeCategory = button.traitCollection.preferredContentSizeCategory
            return ceil(probe.intrinsicContentSize.width)
        }.max() ?? 0
    }

    /// 切り替えのボタンに、今の設定を出す。締め切りのボタンと同じく、どちらの値でも同じ灰色で描く。
    private static func setValue(_ button: UIButton, title: String, symbolName: String) {
        button.configuration?.title = title
        button.configuration?.image = UIImage(systemName: symbolName)
        button.accessibilityValue = title
    }

    private func makeOptionRow(index: Int) -> OptionRow {
        let indicator = UIImageView()
        indicator.tintColor = .tertiaryLabel
        indicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        // 選択肢の文字が長いと、入力欄に押されてマークが潰れたため、マークは縮めない。
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.isAccessibilityElement = false

        let field = ComposeLineField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        // 3つ目からは、書くと次の欄が増えることが分かるよう、足す欄として案内する。
        field.placeholder = index < 2 ? "選択肢\(index + 1)" : "選択肢を追加"
        field.accessibilityLabel = "選択肢\(index + 1)"
        field.returnKeyType = .next
        // 選択肢は短い単語や固有名詞が多く、欄を移ったときに自動修正で替わっても気づきにくいため、修正も先頭の大文字化もしない。
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        onMakeField(field)

        let content = UIStackView(arrangedSubviews: [indicator, field])
        content.alignment = .center
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        // 一覧の投票の選択肢と同じ、角丸のボックスにする。ボックスのどこを押しても、その欄に書き始める。
        let box = UIView()
        box.backgroundColor = .tertiarySystemFill
        box.layer.cornerRadius = 8
        box.layer.cornerCurve = .continuous
        box.addSubview(content)
        box.addGestureRecognizer(UITapGestureRecognizer(target: field, action: #selector(UIResponder.becomeFirstResponder)))
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        return OptionRow(view: box, indicator: indicator, field: field)
    }
}
