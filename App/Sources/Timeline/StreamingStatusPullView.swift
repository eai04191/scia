import SciaCore
import UIKit

/// 一覧を最上部からさらに引っぱったときだけ見える、新着が届く2つの経路の状態の表示。
/// 左にストリーミング、右にRESTでの補完（切れていた間を読む）を並べる。つながっていても補完が終わるまでは新着が出ないため、
/// 「つながっているのに新着が出ない」ときに、どちらで止まっているかを使う人が自分で確かめられるようにする。
/// 切れているときにタイトルの下へ出す表示とは別に、いつでも見られる場所に置く。
///
/// 一覧の内容の上端より上（引っぱると現れる余白）に置く。`contentInset`や内容の大きさは変えないため、スクロール位置を保つ処理に関わらない。
/// 引っぱって離したときの読み直しは一覧の更新コントロールが受け持ち、読んでいる間はこの表示を出さない。
/// 更新コントロールは読んでいる間、一覧のすぐ上に止まり、位置を変えられないため、この表示を間に挟めない。
final class StreamingStatusPullView: UIView {
    /// 今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now
    private let streamingColumn = Column(title: "ストリーミング")
    private let restColumn = Column(title: "REST")
    /// 補完が止まっている理由。列に収まらない長さになるため、2列の下に出す。
    private let noteLabel = UILabel()
    private var observations: [NSKeyValueObservation] = []
    private var streamingState: ConnectionDiagnostics.StreamingState?
    private var arrivalRate = ArrivalRate()
    private var catchUp = CatchUpStatus()

    override init(frame: CGRect) {
        super.init(frame: frame)
        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 0
        let columns = UIStackView(arrangedSubviews: [streamingColumn, restColumn])
        columns.axis = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 16
        let stack = UIStackView(arrangedSubviews: [columns, noteLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 左寄せなので、すぐ下に並ぶ一覧の行と左端をそろえる。
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        updateText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 最初の読み込みが済むまでは、まだつなぎに行っていないため`nil`。
    func setState(_ state: ConnectionDiagnostics.StreamingState?) {
        streamingState = state
        updateText()
        layoutInScrollView()
    }

    func setCatchUp(_ status: CatchUpStatus) {
        catchUp = status
        updateText()
        layoutInScrollView()
    }

    /// 新着が届くたびに呼ばれるため、見えていない間は覚えるだけにする。見え始めたときに作り直す。
    func setArrivalRate(_ rate: ArrivalRate) {
        arrivalRate = rate
        guard alpha > 0 else { return }
        updateText()
        layoutInScrollView()
    }

    private func updateText() {
        let now = now()
        let streaming = Self.streamingContent(for: streamingState, rate: arrivalRate, now: now)
        let rest = Self.restContent(for: catchUp, now: now)
        streamingColumn.show(streaming)
        restColumn.show(rest)
        noteLabel.text = rest.note
        noteLabel.isHidden = rest.note == nil
        accessibilityLabel = [streamingColumn.title, streaming.text, streaming.detail, restColumn.title, rest.text, rest.detail, rest.note]
            .compactMap(\.self)
            .joined(separator: "、")
    }

    /// 一覧の内容の上端の上に置き、引っぱった分だけ見えるようにする。
    func install(in scrollView: UIScrollView) {
        scrollView.addSubview(self)
        // 一覧が画面の高さに満たないときも引っぱれるよう、一覧の側で縦に弾むようにしてある。
        // ナビゲーションバーの後ろが透けるため、引っぱっていないときは見えないよう、引っぱった量で濃さを変える。
        observations = [
            scrollView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.layoutInScrollView() }
            },
            scrollView.observe(\.bounds) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.layoutInScrollView() }
            },
        ]
        layoutInScrollView()
    }

    private func layoutInScrollView() {
        guard let scrollView = superview as? UIScrollView else { return }
        let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        if alpha == 0, pulled > 0 {
            // 流速は時間とともに減り、読み終えた時刻に日付を添えるかは今日かどうかで決まるため、見え始めるたびに作り直す。
            updateText()
        }
        let width = scrollView.bounds.width
        let height = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let newFrame = CGRect(x: 0, y: -height, width: width, height: height)
        if frame != newFrame {
            frame = newFrame
        }
        let progress = min(max(pulled / height, 0), 1)
        alpha = progress
        // 見えていない間は、VoiceOverで読ませない。
        accessibilityElementsHidden = progress == 0
    }

    private struct Content {
        let symbol: String
        let tint: UIColor
        let text: String
        /// 状態の下に小さく添える。流速、読んだ件数、読み終えた時刻。
        var detail: String?
        /// 2列の下に出す、止まっている理由。
        var note: String?
    }

    private static func streamingContent(for state: ConnectionDiagnostics.StreamingState?, rate: ArrivalRate, now: Date) -> Content {
        switch state {
        case .connected:
            Content(symbol: "checkmark.circle.fill", tint: .systemGreen, text: "接続中", detail: "\(rate.perMinute(at: now))件 / 分")
        case .connecting:
            Content(symbol: "ellipsis.circle.fill", tint: .secondaryLabel, text: "接続待ち")
        case .polling:
            Content(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, text: "ポーリング中")
        case .stopped:
            Content(symbol: "pause.circle.fill", tint: .secondaryLabel, text: "停止中")
        case .loginRequired:
            Content(symbol: "pause.circle.fill", tint: .secondaryLabel, text: "ログインが必要")
        case nil:
            Content(symbol: "circle.dashed", tint: .secondaryLabel, text: "未接続")
        }
    }

    private static func restContent(for catchUp: CatchUpStatus, now: Date) -> Content {
        // 止まっている間は、一覧がいつまでの投稿を出しているかを添える。
        let loadedUntil = catchUp.lastLoadedAt.map { "\(time($0, now: now))まで" }
        switch catchUp.phase {
        case .idle:
            guard let loadedAt = catchUp.lastLoadedAt else {
                return Content(symbol: "circle.dashed", tint: .secondaryLabel, text: "読み込み前")
            }
            return Content(symbol: "checkmark.circle.fill", tint: .systemGreen, text: "最新", detail: time(loadedAt, now: now))
        case .loading(let readCount):
            // 何ページで終わるかはサーバーが返さないため、全体は出さず、読んだ件数だけを出す。
            return Content(symbol: "arrow.down.circle.fill", tint: .secondaryLabel, text: "読み込み中", detail: "\(readCount)件")
        case .regenerating:
            return Content(
                symbol: "hourglass.circle.fill",
                tint: .secondaryLabel,
                text: "作り直し待ち",
                detail: loadedUntil,
                note: "サーバーがホームを作り直し中のため、時間をおいて読み直します。"
            )
        case .paused(let until):
            return Content(
                symbol: "pause.circle.fill",
                tint: .systemOrange,
                text: "待機中",
                detail: loadedUntil,
                note: ErrorPresentation(AutomaticRequestsPaused(until: until)).text
            )
        case .failed(let presentation):
            return Content(
                symbol: "exclamationmark.triangle.fill",
                tint: .systemOrange,
                text: "失敗",
                detail: loadedUntil,
                note: "\(presentation.text)次につながったときに読み直します。"
            )
        }
    }

    /// 今日なら時刻だけ、それより前なら日付も添える。
    private static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .standard)
    }

    /// 見出し、アイコンと状態、小さな補足を、左寄せで縦に並べる1列。
    private final class Column: UIStackView {
        let title: String
        private let titleLabel = UILabel()
        private let stateLabel = UILabel()
        private let detailLabel = UILabel()

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
            axis = .vertical
            alignment = .leading
            spacing = 2
            titleLabel.text = title
            titleLabel.font = .preferredFont(forTextStyle: .caption2)
            titleLabel.textColor = .tertiaryLabel
            stateLabel.font = .preferredFont(forTextStyle: .footnote)
            stateLabel.textColor = .label
            stateLabel.numberOfLines = 0
            detailLabel.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            detailLabel.textColor = .secondaryLabel
            detailLabel.numberOfLines = 0
            for label in [titleLabel, stateLabel, detailLabel] {
                label.adjustsFontForContentSizeCategory = true
                addArrangedSubview(label)
            }
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func show(_ content: Content) {
            stateLabel.attributedText = Self.text(content)
            detailLabel.text = content.detail
            detailLabel.isHidden = content.detail == nil
        }

        /// アイコンを文字の頭に埋め込む。折り返しても、アイコンが1行目の文字と並ぶようにする。
        /// 複数行のラベルとアイコンを横に並べると幅が決まらず潰れるため、1つのラベルにまとめる。
        private static func text(_ content: Content) -> NSAttributedString {
            let text = NSMutableAttributedString()
            let symbol = UIImage(systemName: content.symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote))?
                .withTintColor(content.tint, renderingMode: .alwaysOriginal)
            if let symbol {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: content.text))
            return text
        }
    }
}
