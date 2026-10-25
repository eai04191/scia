import SciaCore
import SwiftUI
import UIKit

/// 「投稿の見た目」の上に固定して置くプレビュー。一覧と同じ`PostContentView`で見本の投稿を並べ、触っている項目の場所を色の帯で示す。
final class AppearancePreviewView: UIView {
    /// 部品がタップされたときに、タップした場所に重なる部品を、小さい順に並べて呼ぶ。部品のない場所なら空で呼ぶ。
    var onSelectPart: (([AppearancePreviewPart]) -> Void)?
    /// 示している帯がタップされたときに呼ぶ。
    var onTapHighlight: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [PostContentView] = []
    private var separators: [UIView] = []
    /// 前に描いたときの、数値以外の設定。変わっていれば、部品を動かさずに切り替える。
    private var lastChoices: Int?
    /// 示す帯をまとめるビュー。帯は枠ごとに1つずつ置き、出し入れはこのビューごとフェードする。
    private let highlightView = UIView()
    private var highlight: AppearanceHighlight?
    /// 最後に示した場所。同じ場所なら、スクロールし直さない。
    private var shownHighlight: (highlight: AppearanceHighlight, row: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        highlightView.isUserInteractionEnabled = false
        highlightView.alpha = 0
        scrollView.addSubview(highlightView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameters:
    ///   - showsSeparators: 一覧と同じく、投稿のあいだに区切り線を引く。
    ///   - choices: 数値以外の設定（出すかどうかや表記）を表す値。変わったときは部品を動かさない。
    ///     出していなかった部品は前の位置を持たないため、動かすと、位置0から飛んでくるように見える。
    func apply(_ configurations: [PostContentConfiguration], highlight: AppearanceHighlight?, showsSeparators: Bool = true, choices: Int = 0) {
        let choicesChanged = lastChoices.map { $0 != choices } ?? false
        lastChoices = choices
        if rows.count != configurations.count {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            separators = []
            rows = configurations.map { PostContentView(configuration: $0) }
            // 見本の投稿は押しても動かさず、タップはどの部品かを選ぶのに使う。
            for row in rows {
                row.isUserInteractionEnabled = false
            }
            for (index, row) in rows.enumerated() {
                stack.addArrangedSubview(row)
                // 一覧と同じく、行のあいだに区切り線を引く。返信でつながった行は、線が切れて見えないよう引かない。
                if index < rows.count - 1, !configurations[index].replyConnection.below {
                    let separator = UIView()
                    separator.backgroundColor = .separator
                    separator.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
                    stack.addArrangedSubview(separator)
                    separators.append(separator)
                }
            }
        } else {
            for (row, configuration) in zip(rows, configurations) {
                row.configuration = configuration
            }
            // 余白や大きさを変えたときは、行の中の部品と下の行を、新しい位置まで動かして見せる。どこがどう変わったかを目で追えるようにするため。
            // 文字の大きさは補間できないので、文字は新しい大きさに切り替わり、位置だけが動く。
            if choicesChanged {
                // 動かさない変化は、その場で並べ直しまで済ませる。保留すると、直後の描き直し（示す場所が変わったときなど）の動きの中で並べ直され、
                // 出していなかった部品が位置0から飛んでくる。
                UIView.performWithoutAnimation {
                    self.scrollView.layoutIfNeeded()
                }
            } else if window != nil, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: Self.changeDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.scrollView.layoutIfNeeded()
                    self.updateHighlight()
                }
            }
        }
        // 線を消しても行の位置が変わらないよう、隠さずに透明にする。一覧の区切り線も、行の高さには含まれない。
        for separator in separators {
            separator.alpha = showsSeparators ? 1 : 0
        }
        self.highlight = highlight
        setNeedsLayout()
        // 名前の表記を変えたときなど、行の中のラベルの幅が、このビューを並べ直したあとの並べ直しで決まることがある。
        // そのときは帯が古い幅のまま残るため、今の並べ直しを終えたあとに、もう一度測り直す。
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsLayout()
        }
    }

    /// 部品を囲む枠と、部品のあいだの空き。
    static let encloseOutset: CGFloat = 3

    /// 値を変えたときに、部品を新しい位置まで動かす時間。
    private static let changeDuration: TimeInterval = 0.25

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.layoutIfNeeded()
        updateHighlight()
    }

    private func updateHighlight() {
        guard let highlight, let found = highlight.locate(in: rowFrames()) else {
            shownHighlight = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.highlightView.alpha = 0
            }
            return
        }
        let row = rows[found.row]
        let frames = found.rects.map { row.convert($0, to: scrollView) }
        let isNewPlace = shownHighlight.map { $0.highlight != highlight || $0.row != found.row } ?? true
        shownHighlight = (highlight, found.row)
        // 帯は値を変えるたびに動くので、動かさずにすぐ合わせ、出し入れだけをフェードにする。
        highlightView.frame = scrollView.contentLayoutGuide.layoutFrame.union(scrollView.bounds)
        while highlightView.subviews.count < frames.count {
            let band = UIView()
            highlightView.addSubview(band)
        }
        for (index, band) in highlightView.subviews.enumerated() {
            band.isHidden = index >= frames.count
            guard index < frames.count else { continue }
            // 大きさが0の部品も見えるよう、帯は細くても`minimumGapThickness`の太さにする。
            let rect = Self.visible(highlightView.convert(frames[index], from: scrollView))
            switch found.style {
            case .enclose:
                // 部品は、少し外側に枠を引き、中をほとんど塗らない。示した部品そのものの見た目を隠さないため。
                band.frame = rect.insetBy(dx: -Self.encloseOutset, dy: -Self.encloseOutset)
                band.backgroundColor = .tintColor.withAlphaComponent(0.06)
                band.layer.borderWidth = 1.5
            case .fill:
                band.frame = rect.insetBy(dx: -1, dy: -1)
                band.backgroundColor = .tintColor.withAlphaComponent(0.25)
                band.layer.borderWidth = 1
            }
            band.layer.cornerRadius = min(4, band.frame.height / 2, band.frame.width / 2)
            // 枠の色はCGColorで外観の変化に追従しないため、描くたびに当て直す。
            band.layer.borderColor = UIColor.tintColor.resolvedColor(with: traitCollection).cgColor
        }
        scrollView.bringSubviewToFront(highlightView)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.highlightView.alpha = 1
        }
        // 新しい場所は行ごと見える位置まで、同じ場所は値を変えて広がった分が見えるよう、示す場所だけをスクロールして見せる。
        // 見えていればスクロールしないので、値を変えるたびに一覧が動くことはない。
        // 行がプレビューより高いときは、行の上端ではなく、示す場所を見せる。
        let place = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: 0, dy: -8)
        let withRow = place.union(row.frame)
        let target = isNewPlace && withRow.height <= scrollView.bounds.height ? withRow : place
        scrollView.scrollRectToVisible(target, animated: true)
    }

    /// 見本の行。テストで、行を画像にして確かめるときに使う。
    var rowViews: [PostContentView] {
        rows
    }

    /// 見本の行ごとの、部品の枠。
    func rowFrames() -> [AppearancePreviewFrames] {
        rows.map { $0.previewFrames() }
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        // 示している帯の上なら、どの部品の上でも、示すのをやめる。帯で隠れた見た目を確かめたいときのため。
        let pointInHighlight = recognizer.location(in: highlightView)
        if highlightView.alpha > 0, highlightView.subviews.contains(where: { !$0.isHidden && $0.frame.contains(pointInHighlight) }) {
            onTapHighlight?()
            return
        }
        for row in rows {
            let point = recognizer.location(in: row)
            guard row.bounds.contains(point) else { continue }
            // 小さい部品から先に当てる。行の枠や名前の行のような大きな部品は、中の部品に項目がないときだけ選ぶ。
            let hits = row.previewFrames()
                .filter { $0.value.contains { $0.contains(point) } }
                .sorted { area(of: $0.value) < area(of: $1.value) }
                .map(\.key)
            onSelectPart?(hits)
            return
        }
        onSelectPart?([])
    }

    /// 幅や高さが細すぎる枠を、真ん中を中心に見える太さまで広げる。
    private static func visible(_ rect: CGRect) -> CGRect {
        let thickness = AppearanceHighlight.minimumGapThickness
        return rect.insetBy(dx: min((rect.width - thickness) / 2, 0), dy: min((rect.height - thickness) / 2, 0))
    }

    private func area(of rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }
}

struct AppearancePreview: UIViewRepresentable {
    let configurations: [PostContentConfiguration]
    let highlight: AppearanceHighlight?
    let onSelectPart: ([AppearancePreviewPart]) -> Void
    let onTapHighlight: () -> Void
    var showsSeparators = true
    var choices = 0

    func makeUIView(context: Context) -> AppearancePreviewView {
        AppearancePreviewView()
    }

    func updateUIView(_ view: AppearancePreviewView, context: Context) {
        view.onSelectPart = onSelectPart
        view.onTapHighlight = onTapHighlight
        view.apply(configurations, highlight: highlight, showsSeparators: showsSeparators, choices: choices)
    }
}
