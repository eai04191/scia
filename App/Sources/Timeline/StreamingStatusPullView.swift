import SciaCore
import UIKit

/// 一覧を最上部からさらに引っぱったときだけ見える、ストリーミングの状態の表示。
/// つながっていることを、使う人が自分で確かめられるようにする。切れているときにタイトルの下へ出す表示とは別に、いつでも見られる場所に置く。
///
/// 一覧の内容の上端より上（引っぱると現れる余白）に置く。`contentInset`や内容の大きさは変えないため、スクロール位置を保つ処理に関わらない。
/// 引っぱって離しても、読み直しなどはしない。
final class StreamingStatusPullView: UIView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var observations: [NSKeyValueObservation] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .tertiaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        // 複数行のラベルを中央寄せの積み重ねに入れると幅が決まらず潰れるため、幅いっぱいに置いて文字を中央に揃える。
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        setState(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// まだつないでいない間は`nil`。「接続の状態」画面と同じく、止めているものとして出す。
    func setState(_ state: ConnectionDiagnostics.StreamingState?) {
        let content = Self.content(for: state)
        titleLabel.attributedText = Self.title(content)
        detailLabel.text = content.detail
        detailLabel.isHidden = content.detail == nil
        accessibilityLabel = [content.title, content.detail].compactMap(\.self).joined(separator: "、")
        layoutInScrollView()
    }

    /// 一覧の内容の上端の上に置き、引っぱった分だけ見えるようにする。
    func install(in scrollView: UIScrollView) {
        scrollView.addSubview(self)
        // 一覧が画面の高さに満たないときも、引っぱって状態を確かめられるようにする。
        scrollView.alwaysBounceVertical = true
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
        let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        let progress = min(max(pulled / height, 0), 1)
        alpha = progress
        // 見えていない間は、VoiceOverで読ませない。
        accessibilityElementsHidden = progress == 0
    }

    /// アイコンを文字の頭に埋め込む。折り返しても、アイコンが1行目の文字と並ぶようにする。
    private static func title(_ content: Content) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let symbol = UIImage(systemName: content.symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote))?
            .withTintColor(content.tint, renderingMode: .alwaysOriginal)
        if let symbol {
            title.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: content.title))
        return title
    }

    private struct Content {
        let symbol: String
        let tint: UIColor
        let title: String
        let detail: String?
    }

    private static func content(for state: ConnectionDiagnostics.StreamingState?) -> Content {
        switch state {
        case .connected:
            Content(symbol: "checkmark.circle.fill", tint: .systemGreen, title: "ストリーミングに接続しています", detail: nil)
        case .polling:
            Content(
                symbol: "exclamationmark.triangle.fill",
                tint: .systemOrange,
                title: "ストリーミングに接続できていません",
                detail: "再接続を試しながら、ポーリングで新着を読み込んでいます"
            )
        case .stopped, nil:
            Content(symbol: "pause.circle.fill", tint: .secondaryLabel, title: "ストリーミングを止めています", detail: nil)
        }
    }
}
