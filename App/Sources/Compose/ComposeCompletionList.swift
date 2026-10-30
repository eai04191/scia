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
        Self.contentHeight(of: model.rows)
    }

    static func contentHeight(of rows: [Row]) -> CGFloat {
        rows.map(height(of:)).reduce(0, +) + verticalInset * 2
    }

    init(settings: AppSettings = AppDependencies.settings, emojiImages: EmojiImageStore<UIImage> = AppDependencies.emojiImages) {
        super.init(frame: .zero)
        model.settings = settings
        model.emojiImages = emojiImages
        model.onSelect = { [weak self] candidate in self?.onSelect(candidate) }
        model.onRetry = { [weak self] in self?.onRetry() }
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // 中身の大きさに合わせず、投稿欄が決めた枠（出してよい場所）いっぱいに広げる。ガラスの枠は、その中で候補の数に合わせる。
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

    /// ガラスの枠の外の透明な部分では触れたものを受けず、下の入力欄や一覧へ通す。一覧の枠は、出してよい場所いっぱいに広げているため。
    /// 入れ替えの途中は、まだ並べている前の行も押せるよう、前と後の大きいほうの高さで受ける。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let height = min(max(contentHeight, Self.contentHeight(of: model.displayedRows)), bounds.height)
        let glass = model.growsUpward
            ? CGRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
            : CGRect(x: 0, y: 0, width: bounds.width, height: height)
        return glass.contains(point)
    }

    /// 行を薄くして出し入れする時間。ガラスの伸び縮みと同じ時間。
    var rowFadeDuration: TimeInterval {
        get { model.rowFadeDuration }
        set { model.rowFadeDuration = newValue }
    }

    /// - Parameter animation: 出ている一覧で候補を入れ替えるときの動き。nilなら、すぐ入れ替える。
    ///   前にも後にも同じ場所にある候補はその場に残し、消える候補を薄くしきってから、ガラスの枠を伸び縮みさせて、増えた候補を浮かび上がらせる。
    func update(_ content: ComposeCompletion.Content, kind: CompletionKind, selectedIndex: Int, animation: Animation? = nil) {
        let rows: [Row] = switch content {
        case .candidates(let candidates): candidates.map(Row.candidate)
        case .loading: [.loading]
        case .empty: [.empty(kind)]
        case .failed(let message): [.failed(message)]
        case .candidatesWithFailure(let candidates, let message): candidates.map(Row.candidate) + [.failed(message)]
        }
        if rows != model.rows {
            model.rows = rows
            model.show(rows, animated: animation != nil)
            // 語が変わって候補を入れ替えたら、スクロールを選んでいる候補（ふつうは端の候補）へ戻す。
            model.generation += 1
        } else if animation == nil, model.isSwapping {
            // 入れ替えの途中に閉じて、同じ候補で出し直したときは、途中の入れ替えを捨てて、すぐ並べる。
            model.show(rows, animated: false)
        }
        model.selectedIndex = selectedIndex
        // 選んでいる候補の印は、確定する候補（出したい行の`selectedIndex`番目）と同じ行にだけ付ける。
        // 入れ替えの途中に並べている前の行には付けず、Return・Tabで入る候補と、印の付いた候補が食い違わないようにする。
        model.selectedID = rows.indices.contains(selectedIndex) ? CompletionRowID(row: rows[selectedIndex], index: selectedIndex) : nil
    }
}

/// 行の見分け。中身と、打っている文字に近い端から何番目かの組で見分ける。前にも後にも同じ場所にある候補はその場に残し、
/// 場所が変わった候補は、ほかの行の上を滑らせずに、消してから新しい場所に出す。滑らせると、ほかの行と文字が重なって読めなかった。
private struct CompletionRowID: Hashable {
    let row: ComposeCompletionList.Row
    let index: Int

    static func ids(of rows: [ComposeCompletionList.Row]) -> [CompletionRowID] {
        rows.enumerated().map { CompletionRowID(row: $1, index: $0) }
    }
}

@MainActor
@Observable
private final class CompletionListModel {
    /// 出したい行。投稿欄が置き場所を決めるのに使う。
    @ObservationIgnored var rows: [ComposeCompletionList.Row] = []
    /// いま並べている行。入れ替えの途中は、消える候補を薄くしきるまで、前の行のまま。
    var displayedRows: [ComposeCompletionList.Row] = []
    /// 薄くしている途中の、消える行。
    var fadingOut: Set<CompletionRowID> = []
    /// 薄くしきったら並べる行。薄くしている途中にまた入れ替わったら、ここだけを替える。
    @ObservationIgnored private var pendingRows: [ComposeCompletionList.Row] = []
    /// 薄くしている途中か。
    @ObservationIgnored private(set) var isSwapping = false
    /// 薄くし始めた回数。前の薄くし方の続きを捨てるのに使う。
    @ObservationIgnored private var fadeGeneration = 0

    /// 行を入れ替える。動かすときは、2段に分ける。消える行を薄くしきってから、並べ直してガラスの枠を伸び縮みさせ、増えた行を浮かび上がらせる。
    /// 同時に入れ替えると、消える行と増える行が同じ場所で重なり、文字が二重に読めたため。
    /// 薄くしている途中にまた入れ替わったら、いま並べている行から比べ直し、見えている濃さから続ける。消す行が同じなら、その薄くし方を続け、
    /// 薄くしきったところで最新の行を並べる。同じ値を入れ直しても新しい動きにならず、続きがすぐ呼ばれて、薄くしきる前に行が消えるため。
    func show(_ rows: [ComposeCompletionList.Row], animated: Bool) {
        pendingRows = rows
        guard animated, rowFadeDuration > 0 else {
            fadeGeneration += 1
            isSwapping = false
            fadingOut = []
            displayedRows = rows
            return
        }
        let removed = Set(CompletionRowID.ids(of: displayedRows)).subtracting(CompletionRowID.ids(of: rows))
        guard !removed.isEmpty else {
            fadeGeneration += 1
            isSwapping = false
            withAnimation(.smooth(duration: rowFadeDuration)) {
                fadingOut = []
                displayedRows = rows
            }
            return
        }
        if isSwapping, removed == fadingOut { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        isSwapping = true
        withAnimation(.smooth(duration: rowFadeDuration * 0.4), completionCriteria: .logicallyComplete) {
            fadingOut = removed
        } completion: { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            self.isSwapping = false
            withAnimation(.smooth(duration: self.rowFadeDuration)) {
                self.fadingOut = []
                self.displayedRows = self.pendingRows
            }
        }
    }

    var selectedIndex = 0
    /// 選んでいる候補の行。確定する候補と同じ行にだけ印を付ける。
    var selectedID: CompletionRowID?
    var growsUpward = false
    /// 候補を入れ替えた回数。スクロールを端に戻すのに使う。
    var generation = 0
    /// 行を薄くして出し入れする時間。ガラスの伸び縮みと同じ時間。
    @ObservationIgnored var rowFadeDuration: TimeInterval = 0.25
    @ObservationIgnored var settings = AppDependencies.settings
    @ObservationIgnored var emojiImages = AppDependencies.emojiImages
    @ObservationIgnored var onSelect: (CompletionCandidate) -> Void = { _ in }
    @ObservationIgnored var onRetry: () -> Void = {}
}

private struct CompletionListView: View {
    let model: CompletionListModel

    /// 1行分。何番目かと、そのときの行の中身を一緒に持つ。
    private struct Item: Identifiable {
        let id: CompletionRowID
        let index: Int
        let row: ComposeCompletionList.Row
    }

    /// 下から積むときは、見た目だけを逆に並べる。
    ///
    /// 行には、番号ではなく、この時点で写し取った行の中身を渡す。番号だけを渡して描くときに`model.rows`を読むと、
    /// 候補が減った直後にSwiftUIが古い番号の行を描き直し、範囲外を読んで落ちた（実機で、自分のタグから検索の結果に入れ替わるとき）。
    private func items(_ rows: [ComposeCompletionList.Row]) -> [Item] {
        let all = rows.enumerated().map { index, row in
            Item(id: CompletionRowID(row: row, index: index), index: index, row: row)
        }
        return model.growsUpward ? all.reversed() : all
    }

    private var anchor: UnitPoint {
        model.growsUpward ? .bottom : .top
    }

    /// 増えた行は薄い状態から出す。消える行は、外す前に薄くしきっているので、そのまま外す。
    private var rowTransition: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    /// 行を、打っている文字に近い端からの距離で置き、出してよい場所いっぱいの、大きさの変わらない入れ物に入れる。
    /// ガラスの形と、中身を切り抜く形だけを、候補の数に合わせた高さで動かす。行は、ガラスがどう伸び縮みしてもその場から動かない。
    /// 行をガラスの枠の中に入れて枠ごと高さを動かすと、行がガラスの端に引きずられて動いたため。
    private func anchoredRows(_ items: [Item], rows: [ComposeCompletionList.Row]) -> some View {
        let edge: Alignment = model.growsUpward ? .bottom : .top
        let direction: CGFloat = model.growsUpward ? -1 : 1
        var distances: [CGFloat] = []
        var distance = ComposeCompletionList.verticalInset
        for row in rows {
            distances.append(distance)
            distance += ComposeCompletionList.height(of: row)
        }
        let glassHeight = ComposeCompletionList.contentHeight(of: rows)
        return ZStack(alignment: edge) {
            ForEach(items) { item in
                CompletionRowView(model: model, index: item.index, row: item.row, rowCount: rows.count)
                    .frame(height: ComposeCompletionList.height(of: item.row))
                    .opacity(model.fadingOut.contains(item.id) ? 0 : 1)
                    .offset(y: direction * distances[item.index])
                    .transition(rowTransition)
            }
        }
        .frame(maxWidth: .infinity, idealHeight: glassHeight, maxHeight: .infinity, alignment: edge)
        // 行の背景（`ConcentricRectangle`）を、ガラスの形と同心に丸める。
        .containerShape(.rect(cornerRadius: Self.cornerRadius))
        .mask(alignment: edge) {
            RoundedRectangle(cornerRadius: Self.cornerRadius).frame(height: glassHeight)
        }
        .background(alignment: edge) {
            Color.clear
                .frame(height: glassHeight)
                .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
    }

    private static let cornerRadius: CGFloat = 20

    private func scrollToSelection(_ proxy: ScrollViewProxy, items: [Item]) {
        let selected = items.first { $0.id == model.selectedID } ?? items.first { $0.index == 0 }
        if let selected {
            proxy.scrollTo(selected.id, anchor: selected.index == 0 ? anchor : nil)
        }
    }

    private func rowStack(_ items: [Item], rowCount: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                CompletionRowView(model: model, index: item.index, row: item.row, rowCount: rowCount)
                    .frame(height: ComposeCompletionList.height(of: item.row))
                    .opacity(model.fadingOut.contains(item.id) ? 0 : 1)
                    .transition(rowTransition)
            }
        }
        .padding(.vertical, ComposeCompletionList.verticalInset)
    }

    /// ガラスの枠は、候補の数に合わせた高さにし、打っている文字に近い端に寄せる。候補の数が変わると、反対側の端が伸び縮みする。
    /// 入りきるときはスクロールさせない。入りきらないときだけ、出してよい場所いっぱいのガラスの中でスクロールする。
    /// 中身はガラスの形で切り抜き、伸び縮みの途中に行がガラスの外に描かれないようにする。
    var body: some View {
        let rows = model.displayedRows
        let items = items(rows)
        ViewThatFits(in: .vertical) {
            anchoredRows(items, rows: rows)
            ScrollViewReader { proxy in
                ScrollView {
                    rowStack(items, rowCount: rows.count)
                }
                .scrollBounceBehavior(.basedOnSize)
                // 一覧を引いても、入力欄のキーボードを閉じない。閉じると書き終えたことになり、一覧も消える。
                .scrollDismissesKeyboard(.never)
                .defaultScrollAnchor(anchor, for: .initialOffset)
                .defaultScrollAnchor(anchor, for: .sizeChanges)
                .defaultScrollAnchor(anchor, for: .alignment)
                // 出したときと、語が変わって候補を入れ替えたら、選んでいる候補（ふつうは端の候補）が見えるよう送る。
                .onAppear {
                    scrollToSelection(proxy, items: items)
                }
                .onChange(of: model.generation) {
                    scrollToSelection(proxy, items: items)
                }
                // ハードウェアキーボードで選んだ候補が見えていなければ、見える位置まで送る。
                .onChange(of: model.selectedIndex) { _, index in
                    if let item = items.first(where: { $0.index == index }) {
                        proxy.scrollTo(item.id)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .containerShape(.rect(cornerRadius: Self.cornerRadius))
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("補完の候補")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor == .bottom ? .bottom : .top)
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
                .buttonStyle(RowButtonStyle(isSelected: CompletionRowID(row: row, index: index) == model.selectedID))
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
                RichTextLabel(numberOfLines: 1, emojiImages: model.emojiImages, animatesEmojis: model.settings.animatesCustomEmojis, fadesTail: true) { [model] in
                    RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: model.emojiImages, language: model.settings.glyphLanguageIdentifier())
                        .render(.plain(account.displayNameOrUsername, emojis: account.emojis))
                }
            } subtitle: {
                Text("@\(account.acct)").fadingTail(of: account.acct)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.displayNameOrUsername)、@\(account.acct)")
        case .localAccount(let mention, let source):
            // 検索の結果より上に出る理由が分かるよう、どこから出した人かを添える。
            let note = switch source {
            case .reply: "返信先"
            case .recent: "前にメンションした人"
            }
            RowLayout {
                AvatarImage(url: mention.avatar, shape: model.settings.avatarShape)
            } title: {
                RichTextLabel(numberOfLines: 1, emojiImages: model.emojiImages, animatesEmojis: model.settings.animatesCustomEmojis, fadesTail: true) { [model] in
                    RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: model.emojiImages, language: model.settings.glyphLanguageIdentifier())
                        .render(.plain(mention.displayNameOrUsername, emojis: mention.emojis))
                }
            } subtitle: {
                // 長いハンドルでも、どこから出した人かは切らずに見せる。
                HStack(spacing: 0) {
                    Text("@\(mention.acct)").fadingTail(of: mention.acct)
                    Text("・\(note)").layoutPriority(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(mention.displayNameOrUsername)、@\(mention.acct)、\(note)")
        case .hashtag(let hashtag):
            RowLayout {
                Image(systemName: "number").foregroundStyle(.secondary)
            } title: {
                Text(hashtag.name).fadingTail(of: hashtag.name)
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
                Text(hashtag.name).fadingTail(of: hashtag.name)
            } subtitle: {
                Text(note)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ハッシュタグ \(hashtag.name)、\(note)")
        case .emoji(let emoji):
            RowLayout {
                EmojiImage(url: emoji.staticUrl, animationURL: model.settings.animatesCustomEmojis ? emoji.url : nil, store: model.emojiImages)
            } title: {
                Text(":\(emoji.shortcode):").fadingTail(of: emoji.shortcode)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("絵文字 \(emoji.shortcode)")
        case .standardEmoji(let emoji):
            // 本文と同じ設定の絵（OSの絵文字かtwemoji）で、カスタム絵文字の画像と同じくらいの大きさに描く。
            // 文字ではなく画像と並べる絵なので、端末の文字の大きさではなく枠の大きさで決める。
            RowLayout {
                // swiftlint:disable:next fixed_font_size
                Text(emoji.emoji).font(Font(EmojiFont.font(.systemFont(ofSize: 24), style: model.settings.emojiStyle)))
            } title: {
                Text(emoji.name).fadingTail(of: emoji.name)
            } subtitle: {
                Text(emoji.englishName).fadingTail(of: emoji.englishName)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("絵文字 \(emoji.name)")
        }
    }

    private static func emptyTitle(_ kind: CompletionKind) -> String {
        switch kind {
        case .mention: "一致するアカウントがありません"
        case .hashtag: "一致するハッシュタグがありません"
        case .emoji: "一致する絵文字がありません"
        }
    }
}

/// 候補の1行。左にアイコンか絵文字、右に名前と補足を2段で並べる。長い名前は、名前ごとに`fadingTail`で行末をぼかして切る。
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

private extension View {
    /// 1行に入りきらないときに、「…」で切らず、行末を透明へ向けてぼかす。入りきるときは何もかけない。タイムラインの名前（`FadingLabel`）と同じ見え方にする。
    /// 右から左に書く文字列では、行末は左端なので、文字列の頭を右端にそろえて左端をぼかす。画面の向きではなく、文字列の向きで決める。
    func fadingTail(of text: String) -> some View {
        let isRightToLeft = FadingLabel.isRightToLeft(text)
        return ViewThatFits(in: .horizontal) {
            self
            // 大きさは、ふつうに1行で切った見えない文字で決め、全文は重ねて描くだけにする。全文の幅を大きさにすると、一覧の幅まで広がるため。
            self
                .hidden()
                .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
                .overlay(alignment: isRightToLeft ? .trailing : .leading) {
                    self.fixedSize(horizontal: true, vertical: false)
                }
                .clipped()
                .mask {
                    // FadingLabelの既定と同じく、行末の20ptをぼかす。
                    let fade = LinearGradient(colors: isRightToLeft ? [.clear, .black] : [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                    HStack(spacing: 0) {
                        if isRightToLeft { fade }
                        Color.black
                        if !isRightToLeft { fade }
                    }
                }
        }
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
    /// 元の画像。アニメーション版を読むのに使う。nilなら動かさない。
    let animationURL: URL?
    let store: EmojiImageStore<UIImage>

    func makeUIView(context: Context) -> EmojiImageView {
        let view = EmojiImageView(frame: .zero)
        let coordinator = context.coordinator
        store.addListener(owner: view) { [weak view, weak coordinator] loaded in
            guard let view, let coordinator, let url = coordinator.url else { return }
            if loaded.contains(url) {
                view.stillImage = store.image(for: url)
            }
            if let animationURL = coordinator.animationURL, loaded.contains(animationURL) {
                view.animation = store.animation(for: animationURL)
            }
        }
        return view
    }

    func updateUIView(_ view: EmojiImageView, context: Context) {
        context.coordinator.url = url
        context.coordinator.animationURL = animationURL
        view.stillImage = store.image(for: url)
        view.animation = animationURL.flatMap(store.animation(for:))
    }

    /// アイコンと同じく、画像で大きさの希望が変わらないよう、決まった大きさにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EmojiImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 30)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var url: URL?
        var animationURL: URL?
    }
}
