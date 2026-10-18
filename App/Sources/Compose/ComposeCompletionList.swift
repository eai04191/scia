import Observation
import SciaCore
import SwiftUI
import UIKit

/// 投稿欄の補完の候補の一覧。投稿欄の上に重ね、広げているときは打っている行のすぐ下に重ねる。
///
/// 押しても入力欄のフォーカスは動かさない。候補を押したら`onSelect`、失敗の行を押したら`onRetry`を呼ぶ。
/// ハードウェアキーボードで選んでいる候補は、行の背景で示す。
///
/// いちばん優先する候補を、打っている文字にいちばん近い端に置く。UIKitのメニューの`priority`の並び順と同じ考え方。
/// 入力の上に出すときは下から積み、指と目の動きを短くし、あとから候補が足されても押そうとしている候補を動かさない。
///
/// 中身はSwiftUIで描く。選んでいる行の背景を、一覧の角と同心に丸めるため（`ConcentricRectangle`）。
/// UIKitの`containerConcentric`は、一覧をスクロールしても丸めが付け替わらなかったが、SwiftUIでは追従した。
/// 置き場所の計算とハードウェアキーボードの操作は、投稿欄（UIKit）が受け持つ。
@MainActor
final class ComposeCompletionList: UIView {
    enum Row: Hashable {
        case candidate(CompletionCandidate)
        case loading
        case empty(CompletionKind)
        case failed(String)
    }

    var onSelect: (CompletionCandidate) -> Void = { _ in }
    var onRetry: () -> Void = {}

    private let model = CompletionListModel()
    private lazy var hosting = UIHostingController(rootView: CompletionListView(model: model))
    static let verticalInset: CGFloat = 4

    var rows: [Row] { model.rows }

    /// 下から積む。入力の上に出すときにtrue、打っている行の下に出すときにfalseにする。
    /// 並び（データの順）は優先する順のまま、見た目だけを逆にする。VoiceOverは、いちばん優先する候補から読み上げる。
    var growsUpward: Bool {
        get { model.growsUpward }
        set { model.growsUpward = newValue }
    }

    /// 1行の高さ。文字の大きさの設定に合わせて伸ばす。
    static var rowHeight: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 48)
    }

    /// 行の高さ。失敗の行は、理由を3行まで読めるよう高くする。
    static func height(of row: Row) -> CGFloat {
        guard case .failed = row else { return rowHeight }
        return rowHeight + UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2
    }

    /// 行をすべて見せる高さ。
    var contentHeight: CGFloat {
        model.rows.map(Self.height(of:)).reduce(0, +) + Self.verticalInset * 2
    }

    init(settings: AppSettings = AppDependencies.settings, emojiImages: EmojiImageStore = AppDependencies.emojiImages) {
        super.init(frame: .zero)
        model.settings = settings
        model.emojiImages = emojiImages
        model.onSelect = { [weak self] candidate in self?.onSelect(candidate) }
        model.onRetry = { [weak self] in self?.onRetry() }
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // 中身の大きさに合わせず、投稿欄が決めた枠いっぱいに描く。
        hosting.sizingOptions = []
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ content: ComposeCompletion.Content, kind: CompletionKind, selectedIndex: Int) {
        let rows: [Row] = switch content {
        case .candidates(let candidates): candidates.map(Row.candidate)
        case .loading: [.loading]
        case .empty: [.empty(kind)]
        case .failed(let message): [.failed(message)]
        case .candidatesWithFailure(let candidates, let message): candidates.map(Row.candidate) + [.failed(message)]
        }
        if rows != model.rows {
            model.rows = rows
            // 語が変わって候補を入れ替えたら、スクロールを端に戻す。
            model.generation += 1
        }
        model.selectedIndex = selectedIndex
    }
}

@MainActor
@Observable
private final class CompletionListModel {
    var rows: [ComposeCompletionList.Row] = []
    var selectedIndex = 0
    var growsUpward = false
    /// 候補を入れ替えた回数。スクロールを端に戻すのに使う。
    var generation = 0
    @ObservationIgnored var settings = AppDependencies.settings
    @ObservationIgnored var emojiImages = AppDependencies.emojiImages
    @ObservationIgnored var onSelect: (CompletionCandidate) -> Void = { _ in }
    @ObservationIgnored var onRetry: () -> Void = {}
}

private struct CompletionListView: View {
    let model: CompletionListModel

    /// 1行分。何番目かと、そのときの行の中身を一緒に持つ。
    private struct Item: Identifiable {
        let id: Int
        let row: ComposeCompletionList.Row
    }

    /// 下から積むときは、見た目だけを逆に並べる。
    ///
    /// 行には、番号ではなく、この時点で写し取った行の中身を渡す。番号だけを渡して描くときに`model.rows`を読むと、
    /// 候補が減った直後にSwiftUIが古い番号の行を描き直し、範囲外を読んで落ちた（実機で、自分のタグから検索の結果に入れ替わるとき）。
    private func items(_ rows: [ComposeCompletionList.Row]) -> [Item] {
        let order = model.growsUpward ? Array(rows.indices.reversed()) : Array(rows.indices)
        return order.map { Item(id: $0, row: rows[$0]) }
    }

    private var anchor: UnitPoint {
        model.growsUpward ? .bottom : .top
    }

    var body: some View {
        let rows = model.rows
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items(rows)) { item in
                        CompletionRowView(model: model, index: item.id, row: item.row, rowCount: rows.count)
                            .frame(height: ComposeCompletionList.height(of: item.row))
                            .id(item.id)
                    }
                }
                .padding(.vertical, ComposeCompletionList.verticalInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 一覧を引いても、入力欄のキーボードを閉じない。閉じると書き終えたことになり、一覧も消える。
            .scrollDismissesKeyboard(.never)
            .defaultScrollAnchor(anchor, for: .initialOffset)
            .defaultScrollAnchor(anchor, for: .sizeChanges)
            .defaultScrollAnchor(anchor, for: .alignment)
            .id(model.generation)
            // 候補を入れ替えて作り直すと端に戻るので、選んでいる候補が端でなければ、見える位置まで送り直す。
            .onAppear {
                if model.selectedIndex != 0 {
                    proxy.scrollTo(model.selectedIndex)
                }
            }
            // ハードウェアキーボードで選んだ候補が見えていなければ、見える位置まで送る。
            .onChange(of: model.selectedIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
        // 行の背景（`ConcentricRectangle`）を、この形と同心に丸める。
        .containerShape(.rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("補完の候補")
    }
}

private struct CompletionRowView: View {
    let model: CompletionListModel
    let index: Int
    let row: ComposeCompletionList.Row
    let rowCount: Int

    var body: some View {
        Group {
            switch row {
            case .candidate(let candidate):
                Button {
                    model.onSelect(candidate)
                } label: {
                    candidateLabel(candidate)
                }
                .buttonStyle(RowButtonStyle(isSelected: index == model.selectedIndex))
            case .failed(let message):
                Button {
                    model.onRetry()
                } label: {
                    RowLayout(subtitleLines: 3) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } title: {
                        Text("候補を読み込めませんでした")
                    } subtitle: {
                        Text(message)
                    } trailing: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(RowButtonStyle(isSelected: false))
                .accessibilityLabel("候補を読み込めませんでした。\(message)")
                .accessibilityHint("押すと読み込み直します")
            case .loading:
                RowLayout {
                    ProgressView()
                } title: {
                    Text("候補を探しています").foregroundStyle(.secondary)
                }
            case .empty(let kind):
                RowLayout {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                } title: {
                    Text(Self.emptyTitle(kind)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
        // 見た目が下からでも、いちばん優先する候補から読み上げる。
        .accessibilitySortPriority(Double(rowCount - index))
    }

    @ViewBuilder
    private func candidateLabel(_ candidate: CompletionCandidate) -> some View {
        switch candidate {
        case .account(let account):
            RowLayout {
                AvatarImage(url: account.avatarStatic ?? account.avatar, shape: model.settings.avatarShape)
            } title: {
                RichTextLabel(numberOfLines: 1, emojiImages: model.emojiImages) { [model] in
                    Self.truncatingTail(
                        RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: model.emojiImages, language: model.settings.glyphLanguageIdentifier())
                            .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
                    )
                }
            } subtitle: {
                Text("@\(account.acct)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.displayNameOrUsername)、@\(account.acct)")
        case .hashtag(let hashtag):
            RowLayout {
                Image(systemName: "number").foregroundStyle(.secondary)
            } title: {
                Text(hashtag.name)
            } subtitle: {
                if hashtag.recentUses > 0 {
                    Text("最近の投稿\(hashtag.recentUses)件")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ハッシュタグ \(hashtag.name)")
        case .ownHashtag(let hashtag):
            let note = switch hashtag.source {
            case .featured(let count): "プロフィールのタグ・投稿\(count)件"
            case .recent: "最近使ったタグ"
            }
            // 検索の結果より上に出る理由が分かるよう、自分のタグであることを添える。
            RowLayout {
                Image(systemName: "number").foregroundStyle(.secondary)
            } title: {
                Text(hashtag.name)
            } subtitle: {
                Text(note)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ハッシュタグ \(hashtag.name)、\(note)")
        case .emoji(let emoji):
            RowLayout {
                EmojiImage(url: emoji.staticUrl, store: model.emojiImages)
            } title: {
                Text(":\(emoji.shortcode):")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("絵文字 \(emoji.shortcode)")
        }
    }

    /// 描いた表示名は段落の設定を持ち、ラベルの切り方より優先されるため、長い名前の末尾を「…」で切るよう段落の設定を直す。
    private static func truncatingTail(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    private static func emptyTitle(_ kind: CompletionKind) -> String {
        switch kind {
        case .mention: "一致するアカウントがありません"
        case .hashtag: "一致するハッシュタグがありません"
        case .emoji: "一致する絵文字がありません"
        }
    }
}

/// 候補の1行。左にアイコンか絵文字、右に名前と補足を2段で並べる。長い名前は末尾を切る。
private struct RowLayout<Icon: View, Title: View, Subtitle: View, Trailing: View>: View {
    var subtitleLines = 1
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.subheadline)
                    .lineLimit(1)
                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }
}

extension RowLayout where Subtitle == EmptyView, Trailing == EmptyView {
    init(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title) {
        self.init(icon: icon, title: title, subtitle: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension RowLayout where Trailing == EmptyView {
    init(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder subtitle: () -> Subtitle) {
        self.init(icon: icon, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// 選んでいる行と押している行に背景を付ける。一覧の端に接する角は一覧の角と同心に、離れた角は12ptに丸める。
private struct RowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                if isSelected || configuration.isPressed {
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: false)
                        .fill(Color(uiColor: .tertiarySystemFill))
                }
            }
    }
}

/// アカウントのアイコン。タイムラインと同じ読み込みと形にする。
private struct AvatarImage: UIViewRepresentable {
    let url: URL?
    let shape: AvatarShape

    func makeUIView(context: Context) -> AvatarView {
        AvatarView(store: AppDependencies.avatarImages)
    }

    func updateUIView(_ view: AvatarView, context: Context) {
        view.apply(AvatarView.Content(url: url, shape: shape, animates: false))
    }

    /// 中身は`UIImageView`で、画像が入るたびに大きさの希望が変わる。そのまま使うとSwiftUIが並べ直し続けて止まったため、決まった大きさにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AvatarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 30)
    }
}

/// カスタム絵文字の画像。届いたら描き直す。
private struct EmojiImage: UIViewRepresentable {
    let url: URL
    let store: EmojiImageStore

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        store.addListener(owner: view) { [weak view] loaded in
            guard let view, let url = context.coordinator.url, loaded.contains(url) else { return }
            view.image = store.image(for: url)
        }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        context.coordinator.url = url
        view.image = store.image(for: url)
    }

    /// アイコンと同じく、画像で大きさの希望が変わらないよう、決まった大きさにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 30)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var url: URL?
    }
}
