import SciaCore
import UIKit

/// 投稿欄の投票の欄。本文の下に、選択肢の入力欄と、設定の1行を並べる。決まりは`docs/poll.md`の「投票を作る」。
///
/// 選択肢の欄は、タイムラインの投票と同じく角丸のボックスに入れ、書くとどう見えるかを分かるようにする。欄の数は下書きが決め、最後の欄に書くと空の欄が増える。
/// 空の欄は送らないので、選択肢を足すボタンも消すボタンも置かない。
/// 設定（締め切り、選び方、結果を見せるか）は、今どうなっているかが見え、1回押せば変えられるよう、ボタンを1行に並べる（`ComposePollSettingsRow`）。
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
    /// 折りたたんだ1行を押したときに呼ぶ。置く側が欄を開き、選択肢の入力欄にフォーカスを移す。
    var onUnfold: () -> Void = {}

    /// 選択肢の入力欄。並びの順。
    private(set) var fields: [ComposeLineField] = []
    private var optionRows: [OptionRow] = []
    private let optionsStack = UIStackView()
    /// 設定の1行。値が替わるときの動きのため、SwiftUIで描く。
    private let settingsRow = ComposePollSettingsRow()
    /// 折りたたんだときに、選択肢の欄と設定の行の代わりに出す1行。書いた選択肢を並べ、押すと開く。
    private let summaryButton = FadingTitleButton(configuration: .plain())
    /// 折りたたんだ1行の末尾に置く、押すと開くことを示すシンボル。ボタンの画像は先頭の1つしか置けないので、別のビューで重ねる。
    private let summaryChevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    /// 選択肢の欄と設定の行を入れ、折りたたむと高さを0にして切り抜く入れ物。
    private let expandedContainer = UIView()
    /// 折りたたんだ1行を入れ、開くと高さを0にして切り抜く入れ物。
    private let summaryContainer = UIView()
    /// 入れ物の高さを0にする制約。折りたたむ、開くの動きの中で切り替える。
    private lazy var expandedCollapsed = expandedContainer.heightAnchor.constraint(equalToConstant: 0)
    private lazy var summaryCollapsed = summaryContainer.heightAnchor.constraint(equalToConstant: 0)
    /// 選択肢の欄と設定の行を、1行に折りたたんでいる。小さい画面で本文を書く場所を空けるため、置く側が決める。
    private(set) var isFolded = false
    /// 折りたたむ、開くを切り替えた回数。動き終えたときに、あとから切り替えていないかを見分ける。
    private var foldGeneration = 0
    private(set) var content: Content?
    /// 切り替えのボタンの文言を、設定の行に収まるところまで縮めた段階。
    var labelLength: SettingsLabelLength { settingsRow.labelLength }
    /// 増えて、まだ浮かび上がらせていない欄。
    private var appearingRows: [UIView] = []
    /// 減って並びから外し、まだ薄くし始めていない欄。
    private var leavingRows: [UIView] = []

    /// 選択肢の1行。角丸のボックスに、選び方のマークと入力欄を並べる。
    private struct OptionRow {
        let view: UIView
        let indicator: ComposePollOptionMark
        let field: ComposeLineField
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        optionsStack.spacing = 6
        // 欄が増減するとき、増えた欄や薄くしている欄が、伸び縮みする途中の欄の外へ出て、設定の行に重ならないよう切り抜く。
        // 欄の中身は角丸のボックスの内側に収まり、外へ描くものはない。
        optionsStack.clipsToBounds = true

        settingsRow.onSetExpiry = { [weak self] in self?.onSetExpiry($0) }
        settingsRow.onSetMultiple = { [weak self] in self?.onSetMultiple($0) }
        settingsRow.onSetHidesTotals = { [weak self] in self?.onSetHidesTotals($0) }
        settingsRow.onRemovePoll = { [weak self] in self?.onRemovePoll() }

        configureSummaryButton()
        let expandedContent = UIStackView(arrangedSubviews: [optionsStack, settingsRow])
        expandedContent.axis = .vertical
        expandedContent.spacing = 8
        Self.clip(expandedContent, in: expandedContainer)
        Self.clip(summaryButton, in: summaryContainer)
        expandedContainer.clipsToBounds = false
        summaryCollapsed.isActive = true
        summaryContainer.alpha = 0
        summaryContainer.accessibilityElementsHidden = true
        summaryContainer.isUserInteractionEnabled = false

        let stack = UIStackView(arrangedSubviews: [summaryContainer, expandedContainer])
        stack.axis = .vertical
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
    /// `settingsDuration`が0より大きければ、設定の値と選び方のマークを、その時間で入れ替える。
    /// 欄の数が変わったらtrueを返す。
    @discardableResult
    func apply(_ content: Content, animatesRows: Bool = false, settingsDuration: TimeInterval = 0) -> Bool {
        let multipleChanged = self.content.map { $0.poll.multiple != content.poll.multiple } ?? false
        self.content = content
        let poll = content.poll
        let rowCount = optionRows.count
        while optionRows.count < poll.options.count {
            // マークの形は並べる前に決める。あとから決めると、形の変わるところが、欄を浮かび上がらせる動きに乗る。
            let row = makeOptionRow(index: optionRows.count, multiple: poll.multiple)
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
        for (index, row) in optionRows.enumerated() {
            // 打っている欄に同じ値を入れ直すと、カーソルや変換中の文字が飛ぶため、違うときだけ入れる。
            if row.field.text != poll.options[index] {
                row.field.text = poll.options[index]
            }
            if multipleChanged {
                row.indicator.setMultiple(poll.multiple, duration: settingsDuration)
            }
        }
        settingsRow.apply(
            ComposePollSettings(expiresIn: poll.expiresIn, multiple: poll.multiple, hidesTotals: poll.hidesTotals, expiryChoices: content.expiryChoices),
            duration: settingsDuration
        )
        updateSummary(poll)
        return optionRows.count != rowCount
    }

    /// 選択肢の欄と設定の行を、1行に折りたたむか開く。置く側が、投稿欄の高さを変える動きの中で呼ぶ。
    /// 隠す行の`isHidden`は、変わるときだけ代入する。同じ値を動きの途中に入れ直すと、スタックビューが行を高さ0で並べたまま見せてしまうため。
    /// 隠さずに、入れ物の高さだけを0との間で動かす。`isHidden`で隠すと、スタックビューが中身ごと高さ0へ潰して動きの外で並べ直し、
    /// 閉じ始めに選択肢の文字が○の位置へ一コマで跳んだため。中身は元の大きさのまま上に留め、はみ出した分を切り抜く。
    ///
    /// 返す処理を、動き終えたら（動かさないなら、すぐ）呼ぶ。開き終えたら、選択肢の欄と設定の行を切り抜くのをやめる。
    /// 締め切りのメニューが閉じて戻ってくるボタンは、入れ物の外から入るため、開いている間も切り抜くと欠けて見える。
    /// 開く途中は切り抜く。やめると、伸びる途中の入れ物から設定の行がはみ出して、下のツールバーに重なる。
    @discardableResult
    func setFolded(_ folded: Bool) -> () -> Void {
        guard folded != isFolded else { return {} }
        isFolded = folded
        foldGeneration += 1
        let generation = foldGeneration
        expandedContainer.clipsToBounds = true
        expandedCollapsed.isActive = folded
        summaryCollapsed.isActive = !folded
        expandedContainer.alpha = folded ? 0 : 1
        summaryContainer.alpha = folded ? 1 : 0
        // 切り抜いて見えない側は、読み上げと操作の対象から外す。
        expandedContainer.accessibilityElementsHidden = folded
        summaryContainer.accessibilityElementsHidden = !folded
        expandedContainer.isUserInteractionEnabled = !folded
        summaryContainer.isUserInteractionEnabled = folded
        return { [weak self] in
            // 動いている途中に折りたたみ直したり開き直したりしたら、あとの動きが終えるのを待つ。
            guard let self, generation == foldGeneration, !isFolded else { return }
            expandedContainer.clipsToBounds = false
        }
    }

    /// `content`を`container`の上に留め、`container`の高さを0にしても`content`は元の高さのまま、はみ出した分を切り抜く。
    /// 下端を揃える制約は、入れ物の高さを0にする制約に負け、投稿欄が本文を縮める制約（`defaultLow`）には勝ち、欄の中身が縮まない強さ（`defaultHigh`）より弱くする。
    private static func clip(_ content: UIView, in container: UIView) {
        container.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let bottom = content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        bottom.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom,
        ])
    }

    /// 開いたときの高さ。折りたたんでいても、開いたらどれだけ要るかを測る。
    /// 折りたたむと入れ物の高さを0にするので、入れ物ごと測ると0になる。中身を1つずつ測って足す。
    func unfoldedHeight(width: CGFloat) -> CGFloat {
        func height(of view: UIView) -> CGFloat {
            view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        let options = optionRows.reduce(0) { $0 + height(of: $1.view) } + optionsStack.spacing * CGFloat(max(optionRows.count - 1, 0))
        return 4 + options + 8 + height(of: settingsRow) + 4
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

    /// 折りたたんだ1行を、選択肢の欄と同じ角丸のボックスにする。選択肢の欄の代わりに出ていると分かるようにするため。
    private func configureSummaryButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.background.backgroundColor = .tertiarySystemFill
        configuration.background.cornerRadius = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        configuration.imagePadding = 8
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline)
        configuration.titleLineBreakMode = .byClipping
        summaryButton.configuration = configuration
        summaryButton.contentHorizontalAlignment = .leading
        // 先頭は、＋のメニューで投票を足す項目と同じシンボルにする。選択肢の欄と同じ○や□にすると、まとめた1行が長い選択肢の1つに見えるため。
        summaryButton.configuration?.image = UIImage(systemName: ComposeToolItem.poll.symbolName)
        summaryButton.tintColor = .secondaryLabel
        summaryChevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        summaryChevron.tintColor = .tertiaryLabel
        summaryChevron.setContentHuggingPriority(.required, for: .horizontal)
        summaryChevron.translatesAutoresizingMaskIntoConstraints = false
        summaryButton.addSubview(summaryChevron)
        NSLayoutConstraint.activate([
            summaryChevron.trailingAnchor.constraint(equalTo: summaryButton.trailingAnchor, constant: -10),
            summaryChevron.centerYAnchor.constraint(equalTo: summaryButton.centerYAnchor),
        ])
        summaryButton.accessibilityLabel = "投票の選択肢"
        summaryButton.accessibilityHint = "開いて選択肢を書きます。"
        summaryButton.addAction(UIAction { [weak self] _ in self?.onUnfold() }, for: .primaryActionTriggered)
        // 1行の文字は大きさを決めて入れるので、文字の大きさの設定が変わったら入れ直す。
        summaryButton.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIButton, _) in
            guard let self, let poll = content?.poll else { return }
            updateSummary(poll)
        }
    }

    /// 折りたたんだ1行に、書いた選択肢を出す。選択肢を1つも書いていなければ、書く場所だと分かる案内を出す。
    /// 締め切りは出さない。選択肢のあとに並べると、小さい画面では末尾で切れて読めなかったため。
    private func updateSummary(_ poll: PollDraft) {
        let options = poll.options.filter { !$0.isEmpty }
        var title = AttributedString(options.isEmpty ? "選択肢を書く" : options.joined(separator: "、"))
        title.font = .preferredFont(forTextStyle: .body)
        title.foregroundColor = options.isEmpty ? .placeholderText : .label
        summaryButton.configuration?.attributedTitle = title
        // 選択肢の文字が末尾のシンボルに重ならないよう、シンボルの幅だけ文字の右の余白を空ける。文字の大きさで幅が変わるので、入れ直すたびに測る。
        summaryButton.configuration?.contentInsets.trailing = 10 + summaryChevron.intrinsicContentSize.width + 8
        summaryButton.accessibilityValue = options.isEmpty ? "まだ書いていません" : options.joined(separator: "、")
    }

    private func makeOptionRow(index: Int, multiple: Bool) -> OptionRow {
        let indicator = ComposePollOptionMark(multiple: multiple)
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
        // タイムラインの投票の選択肢と同じ、角丸のボックスにする。ボックスのどこを押しても、その欄に書き始める。
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

/// 選択肢の先頭のマーク。複数選べない投票は丸、複数選べる投票は四角。
///
/// SF Symbolsの`circle`と`square`を置かずに、フチだけの角丸の四角を描く。選び方を変えたときに、線を消して描き直さず、
/// 同じ線のまま角の丸みと大きさを変えて、丸と四角の間を移るため。記号の置き換えは、消して描き直す動きしかない。
/// 大きさ、線の太さ、四角の角の丸みは、タイムラインの投票が使う記号（`subheadline`）に合わせ、文字の大きさに比例させる。
@MainActor
final class ComposePollOptionMark: UIView {
    private(set) var multiple: Bool
    private let shape = UIView()

    /// 記号の文字の大きさ。
    private var pointSize: CGFloat { UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection).pointSize }

    init(multiple: Bool) {
        self.multiple = multiple
        super.init(frame: .zero)
        shape.isUserInteractionEnabled = false
        shape.layer.cornerCurve = .circular
        addSubview(shape)
        applyShape()
        applyColor()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ComposePollOptionMark, _) in
            view.invalidateIntrinsicContentSize()
            view.applyShape()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ComposePollOptionMark, _) in
            view.applyColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter duration: 丸と四角の間を移る時間。0なら、すぐ変える。
    func setMultiple(_ multiple: Bool, duration: TimeInterval) {
        guard multiple != self.multiple else { return }
        self.multiple = multiple
        UIView.animateSmoothly(duration: duration) {
            self.applyShape()
        }
    }

    /// 記号の画像と同じ大きさを取り、記号を置いたときと並びを変えない。丸も四角も、この中央に描く。
    override var intrinsicContentSize: CGSize {
        let configuration = UIImage.SymbolConfiguration(textStyle: .subheadline).applying(UIImage.SymbolConfiguration(traitCollection: traitCollection))
        return UIImage(systemName: "circle", withConfiguration: configuration)?.size ?? CGSize(width: pointSize * 1.2, height: pointSize * 1.2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func applyShape() {
        // 四角は、記号と同じく丸より少し小さい。
        let side = pointSize * (multiple ? 0.94 : 1.06)
        shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shape.layer.cornerRadius = multiple ? pointSize * 0.22 : side / 2
        shape.layer.borderWidth = pointSize * 0.087
    }

    private func applyColor() {
        shape.layer.borderColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
    }
}
