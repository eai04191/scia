import SciaCore
import UIKit

/// 誰が何をしたかの行を主役にする通知のセルの中身。左のアイコンの列の右端に種類の記号を置き、本文の列に、誰が何をしたかの行と、
/// あれば対象の投稿の中身を並べる。
///
/// 投稿の中身は投稿のセルと同じ部品で描き、どの部品をどう出すかは組み立てる側が決める。
/// 2人以上の通知をまとめた行では、誰が何をしたかの行の上に、通知を送った人のアイコンを並べる。
struct NotificationContentConfiguration: UIContentConfiguration {
    var symbolName: String
    var symbolColor: UIColor
    /// 誰が何をしたかの行。名前の前に、文字と同じ高さのアイコンを差し込んである。
    var header: NSAttributedString
    /// まとめた行で、誰が何をしたかの行の上に並べるアイコン。新しい人から。まとめない行では空。
    var groupAvatars: [AvatarView.Content] = []
    /// 通知のもとになる操作をした人の名前。VoiceOverの、プロフィールを開く操作の名前に使う。まとめた行では`groupAccountNames`を使う。
    var accountName: String?
    /// まとめた行で並べたアイコンの人の名前。`groupAvatars`と同じ順。
    var groupAccountNames: [String] = []
    var body: PostBodyContent
    /// 本文の列に置いた中身の種類。「通知の見た目」のプレビューで、本文の部品を通知の部品として示すのに使う。
    var bodyKind: BodyKind = .none
    var metrics: Metrics
    /// 再掲した投稿に、お気に入りやブーストをしたことを示す、行の下の端の光。
    var reactionGlow: ReactionGlow?
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    /// 見出し、注意書き、本文のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore?
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?
    var onToggleSpoiler: (() -> Void)?
    /// 誰が何をしたかの行がタップされたときに呼ぶ。通知のもとになる操作をした人のプロフィールを開く。
    var onOpenAccount: (() -> Void)?
    /// 誰が何をしたかの行（「ほか3人」の文字の外）のタップと長押し。渡すと、タップは`onOpenAccount`の代わりにこれで行う。
    /// 決まりはdocs/object-actions.mdにある。読み上げの操作は、`onOpenAccount`のまま。
    var accountTarget: (any ObjectActionTarget)?
    /// まとめた行で並べたアイコンの、タップと長押し。`groupAvatars`と同じ順に並べる。
    var groupAccountTargets: [any ObjectActionTarget] = []
    /// まとめた行で、並べたアイコンがタップされたときに、何番目かを渡して呼ぶ。その人のプロフィールを開く。
    var onOpenGroupAccount: ((Int) -> Void)?
    /// まとめた行で、誰が何をしたかの行の`groupAccountsLink`の文字（「ほか3人」）がタップされたときに呼ぶ。人の一覧を開く。
    var onOpenGroupAccounts: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?

    enum BodyKind {
        /// 本文の列に何も置かない（まとめた行）。
        case none
        /// フォローなどで、誰が何をしたかの行の下に添えたハンドル。
        case account
        /// お気に入りやブーストで再掲する投稿。
        case quotedPost
    }

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
        /// まとめた行で並べるアイコンの一辺。
        var groupAvatarSize: CGFloat = 0
        /// まとめた行で並べるアイコン同士のすき間。
        var groupAvatarSpacing: CGFloat = 0
        /// まとめた行で、並べたアイコンと、誰が何をしたかの行のあいだ。
        var groupAvatarHeaderSpacing: CGFloat = 0
    }

    func makeContentView() -> any UIView & UIContentView {
        NotificationContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> NotificationContentConfiguration {
        self
    }
}

extension NSAttributedString.Key {
    /// まとめた通知の、誰が何をしたかの行で、押すと人の一覧を開く文字（「ほか3人」）。
    static let groupAccountsLink = NSAttributedString.Key("net.mizle.scia.groupAccountsLink")
}

final class NotificationContentView: UIView, UIContentView {

    private let symbolView = UIImageView()
    /// まとめた行で、誰が何をしたかの行の上に並べるアイコン。
    private let groupAvatarStack = UIStackView()
    /// 並べたアイコンが行の幅に収まらないとき、行の右の余白の手前で切る枠。アイコンの大きさは設定どおりに保つ。
    private let groupAvatarClip = UIView()
    private var groupAvatarViews: [AvatarView] = []
    /// 並べたアイコンの、長押しのメニューと長押しの操作。`groupAvatarViews`と同じ順に並べる。
    private var groupAvatarInteractions: [ObjectInteraction] = []
    /// 誰が何をしたかの行の、長押しのメニューと長押しの操作。
    private var headerInteraction: ObjectInteraction?
    private let headerLabel = EmojiLabel()
    private let bodyView: PostBodyView
    private let reactionGlowView = ReactionGlowView()
    /// 誰が何をしたかの行の最後のベースライン。プレビューで、行の字面の下端を測るのに使う。
    private let headerLastBaselineGuide = UILayoutGuide()
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
        groupAvatarStack.axis = .horizontal
        groupAvatarStack.alignment = .center
        for view in [symbolView, groupAvatarClip, headerLabel, bodyView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        groupAvatarClip.clipsToBounds = true
        groupAvatarStack.translatesAutoresizingMaskIntoConstraints = false
        groupAvatarClip.addSubview(groupAvatarStack)
        // 枠は並べたアイコンの幅に合わせ、行に収まらない分だけ狭める。
        let fitsStack = groupAvatarClip.trailingAnchor.constraint(equalTo: groupAvatarStack.trailingAnchor)
        fitsStack.priority = .defaultHigh
        NSLayoutConstraint.activate([
            groupAvatarStack.topAnchor.constraint(equalTo: groupAvatarClip.topAnchor),
            groupAvatarStack.bottomAnchor.constraint(equalTo: groupAvatarClip.bottomAnchor),
            groupAvatarStack.leadingAnchor.constraint(equalTo: groupAvatarClip.leadingAnchor),
            fitsStack,
        ])
        reactionGlowView.install(in: self)
        addLayoutGuide(headerLastBaselineGuide)
        NSLayoutConstraint.activate([
            headerLastBaselineGuide.topAnchor.constraint(equalTo: headerLabel.lastBaselineAnchor),
            headerLastBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
        ])
        bodyView.onSelectMedia = { [weak self] index, grid in self?.current.onSelectMedia?(index, grid) }
        bodyView.onRevealMedia = { [weak self] in self?.current.onRevealMedia?() }
        bodyView.onToggleSpoiler = { [weak self] in self?.current.onToggleSpoiler?() }
        bodyView.onOpenLink = { [weak self] destination in self?.current.onOpenLink?(destination) }
        headerLabel.isUserInteractionEnabled = true
        headerLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(headerTapped)))
        headerInteraction = ObjectInteraction(on: headerLabel, tapsSelf: false)
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 「ほか3人」の文字なら人の一覧を、ほかの場所なら通知のもとになる操作をした人のプロフィールを開く。
    @objc private func headerTapped(_ gesture: UITapGestureRecognizer) {
        if let index = headerLabel.characterIndex(at: gesture.location(in: headerLabel)),
           headerLabel.attributedText?.attribute(.groupAccountsLink, at: index, effectiveRange: nil) != nil {
            current.onOpenGroupAccounts?()
        } else if let target = current.accountTarget {
            target.perform(.tap, in: headerLabel, at: gesture.location(in: headerLabel))
        } else {
            current.onOpenAccount?()
        }
    }

    @objc private func groupAvatarTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? AvatarView, let index = groupAvatarViews.firstIndex(of: view) else { return }
        if current.groupAccountTargets.indices.contains(index) {
            current.groupAccountTargets[index].perform(.tap, in: view, at: gesture.location(in: view))
        } else {
            current.onOpenGroupAccount?(index)
        }
    }

    /// 並べるアイコンの数に合わせてビューを足し引きし、中身を当てる。
    private func applyGroupAvatars(_ contents: [AvatarView.Content], metrics: NotificationContentConfiguration.Metrics) {
        while groupAvatarViews.count < contents.count {
            let view = AvatarView(store: current.avatarImages)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(groupAvatarTapped)))
            groupAvatarInteractions.append(ObjectInteraction(on: view, tapsSelf: false))
            groupAvatarViews.append(view)
            groupAvatarStack.addArrangedSubview(view)
        }
        while groupAvatarViews.count > contents.count {
            groupAvatarViews.removeLast().removeFromSuperview()
            groupAvatarInteractions.removeLast()
        }
        for (index, interaction) in groupAvatarInteractions.enumerated() {
            interaction.target = current.groupAccountTargets.indices.contains(index) ? current.groupAccountTargets[index] : nil
        }
        groupAvatarStack.spacing = metrics.groupAvatarSpacing
        for (view, content) in zip(groupAvatarViews, contents) {
            view.apply(content)
        }
        groupAvatarClip.isHidden = contents.isEmpty
    }

    private func apply(_ configuration: NotificationContentConfiguration) {
        current = configuration
        headerInteraction?.target = configuration.accountTarget
        let metrics = configuration.metrics
        // ベースラインの位置を読むため、大きさの設定を画像そのものに当てておく。
        symbolView.image = UIImage(systemName: configuration.symbolName, withConfiguration: UIImage.SymbolConfiguration(font: metrics.headerFont))
        symbolView.tintColor = configuration.symbolColor
        headerLabel.emojiImages = configuration.emojiImages
        headerLabel.attributedText = configuration.header
        applyGroupAvatars(configuration.groupAvatars, metrics: metrics)
        bodyView.emojiImages = configuration.emojiImages
        bodyView.apply(configuration.body)
        reactionGlowView.apply(configuration.reactionGlow)

        NSLayoutConstraint.deactivate(variableConstraints)
        let margins = metrics.margins
        let textLeading = margins.leading + metrics.avatarSize + metrics.avatarSpacing
        // 一覧は行の高さを画素に丸め、求める高さより1画素未満だけ低くすることがある。足りない分は文字のラベルではなく下の余白から削る。
        // ラベルから削ると、UILabelは収まらない行を描かないため、2行の本文が1行で切れる。
        let bottom = bottomAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: margins.bottom)
        bottom.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue - 1)
        // まとめた行では、アイコンを並べた下に誰が何をしたかの行を置く。
        let headerTop = configuration.groupAvatars.isEmpty
            ? headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top)
            : headerLabel.topAnchor.constraint(equalTo: groupAvatarClip.bottomAnchor, constant: metrics.groupAvatarHeaderSpacing)
        let groupAvatarSizes = groupAvatarViews.flatMap { view in
            [view.widthAnchor.constraint(equalToConstant: metrics.groupAvatarSize), view.heightAnchor.constraint(equalToConstant: metrics.groupAvatarSize)]
        }
        variableConstraints = groupAvatarSizes + [
            groupAvatarClip.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            groupAvatarClip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            groupAvatarClip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margins.trailing),
            // 記号は、投稿のセルの名前の上の行と同じく、文字の列から決まった幅だけ離して置く。
            symbolView.trailingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading - metrics.symbolSpacing),
            // 記号は、メンションなどの名前の上の行の記号と同じく、文字の1行目のベースラインに乗せる。
            PostContentView.symbolVerticalConstraint(symbolView, beside: headerLabel, onBaseline: true),
            headerTop,
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            // 間隔は、誰が何をしたかの行の字面の下端から測る。
            bodyView.topAnchor.constraint(equalTo: headerLabel.lastBaselineAnchor, constant: metrics.bodySpacing + metrics.headerFont.pointSize * PostBodyView.emBoxDescent),
            bodyView.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
            bottom,
        ]
        NSLayoutConstraint.activate(variableConstraints)
        updateAccessibility(for: configuration)
    }

    /// 読み上げでは、誰が何をしたかの行と本文を1つの要素として読む。サムネイルは別の要素のまま残す。
    private func updateAccessibility(for configuration: NotificationContentConfiguration) {
        textAccessibilityElement.accessibilityLabel = [configuration.header.string, bodyView.accessibilityText, configuration.reactionGlow?.accessibilityText ?? ""]
            // 名前の前に差し込んだアイコンの文字は読まない。
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
        // まとめた行の「ほか3人」は文字の中にあり、読み上げでは押せないため、操作として足す。
        let groupAccountsAction = configuration.onOpenGroupAccounts.map { open in
            UIAccessibilityCustomAction(name: "通知を送った人の一覧") { _ in
                open()
                return true
            }
        }
        textAccessibilityElement.accessibilityCustomActions = [groupAccountsAction, bodyView.spoilerAccessibilityAction()].compactMap(\.self) + bodyView.linkAccessibilityActions()
            + profileAccessibilityActions(for: configuration)
        // 枠はlayoutSubviewsで決める。大きさの変わらない描き直し（絵文字の画像が届いたときなど）では並べ直しが起きないため、枠を空にせず、並べ直しを頼む。
        // 空にすると、次に並べ直すまで、VoiceOverで指でなぞってもこの行に止まらない。
        setNeedsLayout()
        accessibilityElements = [textAccessibilityElement] + (bodyView.poll?.accessibilityParts ?? []) + [bodyView.mediaGrid, bodyView.linkCard].compactMap(\.self)
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    /// 誰が何をしたかの行と、まとめた行のアイコンのタップで開くプロフィールを、VoiceOverでは操作として開く。
    /// まとめた行では、並べたアイコンの人ごとに出す。行のタップで開く人は、アイコンの先頭の人と同じなので重ねない。
    private func profileAccessibilityActions(for configuration: NotificationContentConfiguration) -> [UIAccessibilityCustomAction] {
        if let open = configuration.onOpenGroupAccount, !configuration.groupAccountNames.isEmpty {
            return configuration.groupAccountNames.enumerated().map { index, name in
                UIAccessibilityCustomAction(name: "\(name)のプロフィール") { _ in
                    open(index)
                    return true
                }
            }
        }
        guard let open = configuration.onOpenAccount, let name = configuration.accountName else { return [] }
        return [UIAccessibilityCustomAction(name: "\(name)のプロフィール") { _ in
            open()
            return true
        }]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reactionGlowView.layout(in: bounds, bottomMargin: current.metrics.margins.bottom)
        // 本文の枠は中身の部品の中で決まるため、先に並べておく。
        bodyView.layoutIfNeeded()
        let bodyTextFrame = bodyView.convert(bodyView.textFrame, to: self)
        textAccessibilityElement.accessibilityFrameInContainerSpace = headerLabel.frame.union(bodyTextFrame).union(symbolView.frame)
    }
}

extension NotificationContentView {
    /// 「通知の見た目」のプレビューで示す、部品ごとの枠。本文の列の部品は、置いた中身の種類で通知の部品に読み替える。
    func previewFrames() -> AppearancePreviewFrames {
        var frames: AppearancePreviewFrames = [
            .notificationSymbol: symbolView.image == nil ? nil : symbolView.previewFrame(in: self),
            .notificationHeader: headerLabel.previewFrame(in: self),
            .notificationHeaderGlyphs: headerGlyphsFrame(),
        ].compactMapValues(\.self)
        frames.merge(headerAvatarPreviewFrames()) { $1 }
        frames.merge(groupAvatarPreviewFrames()) { $1 }
        let body = bodyView.previewFrames(in: self)
        switch current.bodyKind {
        case .none:
            break
        case .account:
            frames[.notificationAccount] = body[.bodyText]
            frames[.notificationAccountGlyphs] = body[.bodyGlyphs]
        case .quotedPost:
            let parts: [AppearancePreviewPart: AppearancePreviewPart] = [
                .spoiler: .quotedSpoiler,
                .bodyText: .quotedBodyText,
                .bodyGlyphs: .quotedBodyGlyphs,
                .media: .quotedMedia,
                .poll: .quotedPoll,
                .filterNote: .quotedNote,
            ]
            for (part, quoted) in parts {
                frames[quoted] = body[part]
            }
            if let tiles = bodyView.mediaGrid?.tilePreviewFrames(in: self), !tiles.isEmpty {
                frames[.quotedThumbnails] = tiles
                if tiles.count > 1 {
                    frames[.quotedThumbnailGaps] = Self.gaps(inRow: tiles)
                }
            }
        }
        return frames
    }

    /// 誰が何をしたかの行の字面。上端はラベルの上端、下端は最後のベースラインからem枠で測る。下に置く中身との間隔は、この下端から測るため。
    private func headerGlyphsFrame() -> [CGRect]? {
        guard let label = headerLabel.previewFrame(in: self)?.first else { return nil }
        let bottom = headerLastBaselineGuide.layoutFrame.minY + current.metrics.headerFont.pointSize * PostBodyView.emBoxDescent
        return [CGRect(x: label.minX, y: label.minY, width: label.width, height: max(bottom - label.minY, 0))]
    }

    /// 名前の前に差し込んだアイコンと、アイコンと名前のすき間。アイコンを差し込んでいなければ空。
    private func headerAvatarPreviewFrames() -> AppearancePreviewFrames {
        guard let text = headerLabel.attributedText, !headerLabel.isHidden else { return [:] }
        var index: Int?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard value != nil else { return }
            index = range.location
            stop.pointee = true
        }
        guard let index else { return [:] }
        let layout = headerLabel.textLayout(of: text)
        func frame(at index: Int) -> CGRect? {
            guard index < text.length else { return nil }
            return headerLabel.characterFrame(at: index, in: text, contentStorage: layout.contentStorage, layoutManager: layout.layoutManager)
                .map { headerLabel.convert($0, to: self) }
        }
        guard let avatar = frame(at: index) else { return [:] }
        var frames: AppearancePreviewFrames = [.notificationHeaderAvatar: [avatar]]
        // すき間は、アイコンの後ろの空白の幅と、その字送りの和。TextKit 2で空白の後ろの文字の位置を測ると、空白の字送りがUILabelの描く位置どおりに入らない（字送りを20増やしても6.5しか動かなかった）ため、文字の属性から求める。
        if index + 1 < text.length, let font = text.attribute(.font, at: index + 1, effectiveRange: nil) as? UIFont {
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            let kern = text.attribute(.kern, at: index + 1, effectiveRange: nil) as? CGFloat ?? 0
            frames[.notificationHeaderAvatarGap] = [CGRect(x: avatar.maxX, y: avatar.minY, width: max(space + kern, 0), height: avatar.height)]
        }
        return frames
    }

    /// まとめた行で並べたアイコンと、アイコン同士のあいだ。行の幅で切れた分は、見えている部分だけにする。
    private func groupAvatarPreviewFrames() -> AppearancePreviewFrames {
        guard !groupAvatarClip.isHidden, !groupAvatarViews.isEmpty else { return [:] }
        let clip = groupAvatarClip.convert(groupAvatarClip.bounds, to: self)
        let avatars = groupAvatarViews.compactMap { view -> CGRect? in
            let frame = view.convert(view.bounds, to: self)
            // 大きさ0のアイコンも場所を示せるよう、切る枠と重ならないときだけ除く。
            guard frame.minX < clip.maxX || frame.width == 0 else { return nil }
            return CGRect(x: frame.minX, y: frame.minY, width: max(min(frame.maxX, clip.maxX) - frame.minX, 0), height: frame.height)
        }
        var frames: AppearancePreviewFrames = [.groupAvatars: avatars]
        if avatars.count > 1 {
            frames[.groupAvatarGaps] = Self.gaps(inRow: avatars)
        }
        return frames
    }

    /// 1列に並べた枠の、隣り合うもののあいだ。`AppearanceHighlight.gaps(between:)`は縦の重なりで隣を探すため、
    /// 大きさを0にして高さのない枠では隣が見つからず、帯がなくなる。1列と分かっているので、左から順に隣とみなす。
    private static func gaps(inRow frames: [CGRect]) -> [CGRect] {
        let sorted = frames.sorted { $0.minX < $1.minX }
        return zip(sorted, sorted.dropFirst()).map { left, right in
            CGRect(x: left.maxX, y: left.minY, width: max(right.minX - left.maxX, 0), height: left.height)
        }
    }
}
