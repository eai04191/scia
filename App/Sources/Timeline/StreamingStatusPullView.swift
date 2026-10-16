import SciaCore
import UIKit

/// 一覧を最上部からさらに引っぱったときだけ見える、ストリーミングの状態の表示。
/// つながっていることを、使う人が自分で確かめられるようにする。切れているときにタイトルの下へ出す表示とは別に、いつでも見られる場所に置く。
///
/// 一覧の内容の上端より上（引っぱると現れる余白）に置く。`contentInset`や内容の大きさは変えないため、スクロール位置を保つ処理に関わらない。
/// 引っぱって離しても、読み直しなどはしない。
final class StreamingStatusPullView: UIView {
    private let label = UILabel()
    private var observations: [NSKeyValueObservation] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        setState(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 最初の読み込みが済むまでは、まだつなぎに行っていないため`nil`。
    func setState(_ state: ConnectionDiagnostics.StreamingState?) {
        let content = Self.content(for: state)
        label.attributedText = Self.text(content)
        accessibilityLabel = content.text
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

    private struct Content {
        let symbol: String
        let tint: UIColor
        let text: String
    }

    private static func content(for state: ConnectionDiagnostics.StreamingState?) -> Content {
        switch state {
        case .connected:
            Content(symbol: "checkmark.circle.fill", tint: .systemGreen, text: "ストリーミング接続中")
        case .connecting:
            Content(symbol: "ellipsis.circle.fill", tint: .secondaryLabel, text: "ストリーミング接続待ち")
        case .polling:
            Content(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, text: "ストリーミング切断中・ポーリング中")
        case .stopped:
            Content(symbol: "pause.circle.fill", tint: .secondaryLabel, text: "ストリーミング停止中")
        case .loginRequired:
            Content(symbol: "pause.circle.fill", tint: .secondaryLabel, text: "ストリーミング停止中（ログインが必要）")
        case nil:
            Content(symbol: "circle.dashed", tint: .secondaryLabel, text: "ストリーミング未接続")
        }
    }
}
