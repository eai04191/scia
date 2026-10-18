import SciaCore
import UIKit

/// 誰が何をしたかの行を主役にする通知のセルの中身。左のアイコンの列の右端に種類の記号を置き、本文の列に、誰が何をしたかの行と、
/// あれば対象の投稿の中身を並べる。
///
/// 投稿の中身は投稿のセルと同じ部品で描き、どの部品をどう出すかは組み立てる側が決める。
struct NotificationContentConfiguration: UIContentConfiguration {
    var symbolName: String
    var symbolColor: UIColor
    /// 誰が何をしたかの行。名前の前に、文字と同じ高さのアイコンを差し込んである。
    var header: NSAttributedString
    var body: PostBodyContent
    var metrics: Metrics
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?
    var onToggleSpoiler: (() -> Void)?
    /// 誰が何をしたかの行がタップされたときに呼ぶ。通知のもとになる操作をした人のプロフィールを開く。
    var onOpenAccount: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?

    /// 大きさと文字の見た目。
    struct Metrics {
        var margins: NSDirectionalEdgeInsets
        /// 投稿のセルのアイコンの一辺。本文の列の左端を投稿のセルと揃えるため、同じ幅の列を空ける。
        var avatarSize: CGFloat
        var headerFont: UIFont
        /// 誰が何をしたかの行と、投稿の中身のあいだの余白。
        var bodySpacing: CGFloat
        /// 記号と、誰が何をしたかの行の文字とのすき間。
        var symbolSpacing: CGFloat
        /// アイコンの列と、文字の列のあいだ。
        var avatarSpacing: CGFloat
    }

    func makeContentView() -> any UIView & UIContentView {
        NotificationContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> NotificationContentConfiguration {
        self
    }
}

final class NotificationContentView: UIView, UIContentView {

    private let symbolView = UIImageView()
    private let headerLabel = UILabel()
    private let bodyView: PostBodyView
    private var current: NotificationContentConfiguration
    /// 大きさで変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    var configuration: any UIContentConfiguration {
        get { current }
        set {
            guard let configuration = newValue as? NotificationContentConfiguration else { return }
            apply(configuration)
        }
    }

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        bodyView.mediaGrid
    }

    init(configuration: NotificationContentConfiguration) {
        current = configuration
        bodyView = PostBodyView(mediaImages: configuration.mediaImages, avatarImages: configuration.avatarImages)
        super.init(frame: .zero)
        symbolView.contentMode = .scaleAspectFit
        headerLabel.numberOfLines = 0
        for view in [symbolView, headerLabel, bodyView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bodyView.onSelectMedia = { [weak self] index, grid in self?.current.onSelectMedia?(index, grid) }
        bodyView.onRevealMedia = { [weak self] in self?.current.onRevealMedia?() }
        bodyView.onToggleSpoiler = { [weak self] in self?.current.onToggleSpoiler?() }
        bodyView.onOpenLink = { [weak self] destination in self?.current.onOpenLink?(destination) }
        headerLabel.isUserInteractionEnabled = true
        headerLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAccount)))
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openAccount() {
        current.onOpenAccount?()
    }

    private func apply(_ configuration: NotificationContentConfiguration) {
        current = configuration
        let metrics = configuration.metrics
        // ベースラインの位置を読むため、大きさの設定を画像そのものに当てておく。
        symbolView.image = UIImage(systemName: configuration.symbolName, withConfiguration: UIImage.SymbolConfiguration(font: metrics.headerFont))
        symbolView.tintColor = configuration.symbolColor
        headerLabel.attributedText = configuration.header
        bodyView.apply(configuration.body)

        NSLayoutConstraint.deactivate(variableConstraints)
        let margins = metrics.margins
        let textLeading = margins.leading + metrics.avatarSize + metrics.avatarSpacing
        variableConstraints = [
            // 記号は、投稿のセルの名前の上の行と同じく、文字の列から決まった幅だけ離して置く。
            symbolView.trailingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading - metrics.symbolSpacing),
            // 記号は、メンションなどの名前の上の行の記号と同じく、文字の1行目のベースラインに乗せる。
            PostContentView.symbolVerticalConstraint(symbolView, beside: headerLabel, onBaseline: true),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            // 間隔は、誰が何をしたかの行の字面の下端から測る。
            bodyView.topAnchor.constraint(equalTo: headerLabel.lastBaselineAnchor, constant: metrics.bodySpacing + metrics.headerFont.pointSize * PostBodyView.emBoxDescent),
            bodyView.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            bottomAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: margins.bottom),
        ]
        NSLayoutConstraint.activate(variableConstraints)
        updateAccessibility(for: configuration)
    }

    /// 読み上げでは、誰が何をしたかの行と本文を1つの要素として読む。サムネイルは別の要素のまま残す。
    private func updateAccessibility(for configuration: NotificationContentConfiguration) {
        textAccessibilityElement.accessibilityLabel = [configuration.header.string, bodyView.accessibilityText]
            // 名前の前に差し込んだアイコンの文字は読まない。
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
        textAccessibilityElement.accessibilityCustomActions = [bodyView.spoilerAccessibilityAction()].compactMap(\.self) + bodyView.linkAccessibilityActions()
        // 枠はlayoutSubviewsで決める。大きさの変わらない描き直し（絵文字の画像が届いたときなど）では並べ直しが起きないため、枠を空にせず、並べ直しを頼む。
        // 空にすると、次に並べ直すまで、VoiceOverで指でなぞってもこの行に止まらない。
        setNeedsLayout()
        accessibilityElements = [textAccessibilityElement] + [bodyView.mediaGrid, bodyView.linkCard].compactMap(\.self)
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    override func layoutSubviews() {
        super.layoutSubviews()
        // 本文の枠は中身の部品の中で決まるため、先に並べておく。
        bodyView.layoutIfNeeded()
        let bodyTextFrame = bodyView.convert(bodyView.textFrame, to: self)
        textAccessibilityElement.accessibilityFrameInContainerSpace = headerLabel.frame.union(bodyTextFrame).union(symbolView.frame)
    }
}
