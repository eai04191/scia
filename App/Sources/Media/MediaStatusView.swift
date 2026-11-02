import UIKit

/// ビューアのページの中央に出す、読み込み中と、見せられないことの表示。動画とGIFの最初のコマを描くまでと、画像、動画、GIFを読み込めなかったとき、
/// アプリで表示できない種類のファイルで使う。見せられないときは、ブラウザで開けるなら「ブラウザで開く」を添える。
/// ページいっぱいに広げ、「ブラウザで開く」のほかのタッチは受けずに、下の画像や映像に渡す。
///
/// 明るいサムネイルの上でも読めるよう、半透明の黒の下地に白で描く。下地をぼかし（`UIVisualEffectView`）にしないのは、
/// 閉じ始めにビューアが描き写す複製（`snapshotView`）にぼかしが写らず、下地だけが一コマで消えるため。
final class MediaStatusView: UIView {
    enum State: Equatable {
        case hidden
        case loading
        /// 見せられない。値は出す文言。
        case failed(String)
    }

    private(set) var state = State.hidden
    /// 見せられないときに「ブラウザで開く」で呼ぶ。nilならボタンを出さない。
    var onOpen: (() -> Void)? {
        didSet { openButton.isHidden = onOpen == nil }
    }

    private let circle = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let capsule = UIView()
    private let failureLabel = UILabel()
    private let openButton = UIButton(configuration: .filled())

    override init(frame: CGRect) {
        super.init(frame: frame)
        for platter in [circle, capsule] {
            platter.translatesAutoresizingMaskIntoConstraints = false
            platter.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            platter.alpha = 0
            addSubview(platter)
        }
        circle.layer.cornerRadius = Self.circleDiameter / 2
        capsule.layer.cornerRadius = Self.capsuleCornerRadius
        capsule.layer.cornerCurve = .continuous
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(spinner)
        failureLabel.font = .preferredFont(forTextStyle: .subheadline)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.textColor = .white
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        openButton.configuration?.title = "ブラウザで開く"
        openButton.configuration?.baseForegroundColor = .white
        // 半透明の黒の下地の上でボタンと分かるよう、下地より明るくする。
        openButton.configuration?.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        openButton.configuration?.cornerStyle = .capsule
        openButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        openButton.isHidden = true
        openButton.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [failureLabel, openButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(stack)
        let padding = Self.capsulePadding
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: Self.circleDiameter),
            circle.heightAnchor.constraint(equalToConstant: Self.circleDiameter),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
            stack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: padding.top),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -padding.bottom),
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: padding.left),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -padding.right),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 「ブラウザで開く」のほかは、下の画像や映像のタップ、ダブルタップ、長押しに渡す。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard case .failed = state, !openButton.isHidden, capsule.alpha > 0 else { return false }
        return openButton.point(inside: convert(point, to: openButton), with: event)
    }

    /// 「ブラウザで開く」に触れているか。ページのジェスチャーに、そのタッチを渡さないために使う。
    func isOpenButtonTouch(_ touch: UITouch) -> Bool {
        touch.view?.isDescendant(of: openButton) == true
    }

    /// 出すものを替える。`animated`なら、前に出していたものを薄くして消し、新しく出すものを浮かび上がらせる。
    func setState(_ state: State, animated: Bool) {
        guard state != self.state else { return }
        self.state = state
        if case .failed(let text) = state {
            failureLabel.text = text
        }
        if state == .loading {
            spinner.startAnimating()
        }
        let changes = {
            self.circle.alpha = state == .loading ? 1 : 0
            self.capsule.alpha = if case .failed = state { 1 } else { 0 }
        }
        let completion = { [weak self] in
            guard let self, self.state != .loading else { return }
            self.spinner.stopAnimating()
        }
        guard animated else {
            changes()
            completion()
            return
        }
        UIView.animateSmoothly(duration: Self.fadeDuration, changes: changes, completion: completion)
    }

    /// 動画の操作の部品の出し入れ（`VideoControlsView.setControlsHidden`）と揃える。
    static let fadeDuration: TimeInterval = 0.2
    private static let circleDiameter: CGFloat = 48
    private static let capsuleCornerRadius: CGFloat = 12
    private static let capsulePadding = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
}
