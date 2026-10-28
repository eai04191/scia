import SwiftUI
import UIKit

/// プロフィールのフォローのボタン。文字が替わるときに、前後に共通する文字は残して替わる文字だけを入れ替え（`numericText`）、
/// カプセルの幅と色を同じスプリングで変えるため、SwiftUIで描いてUIKitのヘッダーに載せる。
///
/// 枠の幅は、出しうる文字のうちいちばん長いものに合わせて変えない。カプセルはその右端に寄せて描き、幅の変化はSwiftUIの中だけで動かす。
/// 枠の幅を文字に合わせて変えると、UIKitの並べ直しとSwiftUIの動きが別々に進み、カプセルが跳んで見えるため。
/// 色と余白は、UIKitの`UIButton.Configuration`の標準の形（塗りつぶし、ティント、灰色）から取り、ほかのボタンと揃える。
@MainActor
final class ProfileFollowButton: UIView {
    enum Style: Equatable {
        case filled
        case tinted
        case gray
    }

    struct State: Equatable {
        var title: String
        var style: Style
        /// 関係を読む前。文字を消して場所だけ取り、押せなくする。
        var isPlaceholder = false
        /// 関係を待つのが長引いている。場所を取ったカプセルの中に、アクティビティインジケータを出す。
        var showsActivity = false
        /// フォローを変えている途中。文字の前にアクティビティインジケータを出し、押せなくする。
        var isChanging = false
    }

    /// 出しうる文字。枠の幅を、このうちいちばん長いものに合わせる。
    static let titles = ["フォローする", "フォローをリクエスト", "リクエスト中", "フォロー中", "プロフィールを編集"]

    var onTap: (() -> Void)?
    /// 塗りつぶしたボタンの地と文字の色。nilならティントカラーと白で塗る。
    var filledColors: (fill: UIColor, foreground: UIColor)? {
        didSet { refreshColors(animation: nil) }
    }

    private(set) var state: State?
    private let model = ProfileFollowButtonModel()
    private lazy var hosting = UIHostingController(rootView: ProfileFollowButtonView(model: model))
    /// 標準の形の色を、ティントカラーと見た目のモードに合わせて読むためのボタン。画面には置かない。
    private let colorSource = UIButton(configuration: .filled())
    private var reservedWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        model.onTap = { [weak self] in self?.onTap?() }
        let standard = UIButton.Configuration.filled()
        model.contentInsets = standard.contentInsets
        model.imagePadding = standard.imagePadding
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // 中身の大きさに合わせず、決めた枠いっぱいに広げる。カプセルは右端に寄せて描く。
        hosting.sizingOptions = []
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ProfileFollowButton, _) in
            view.refreshColors(animation: nil)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ProfileFollowButton, _) in
            view.reservedWidth = nil
            view.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter animation: 文字、幅、色を変える動き。nilなら、すぐ変える。
    func apply(_ state: State, animation: Animation?) {
        guard state != self.state else { return }
        self.state = state
        perform(animation) {
            self.model.state = state
            self.model.colors = self.colors(for: state.style)
        }
    }

    /// ティントカラーやカードの色が替わったときに、色を塗り直す。
    func refreshColors(animation: Animation?) {
        guard let state else { return }
        let colors = colors(for: state.style)
        guard colors != model.colors else { return }
        perform(animation) { self.model.colors = colors }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        refreshColors(animation: nil)
    }

    override var intrinsicContentSize: CGSize {
        let width = reservedWidth ?? measureReservedWidth()
        reservedWidth = width
        return CGSize(width: width, height: measure(title: Self.titles[0]).height)
    }

    /// カプセルの外の透明な部分では触れたものを受けない。枠は、いちばん長い文字の幅で取っているため。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let width = min(model.capsuleWidth, bounds.width)
        return CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height).contains(point)
    }

    /// 確認のシートを指す場所。
    var capsuleFrame: CGRect {
        let width = min(model.capsuleWidth, bounds.width)
        return CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
    }

    private func perform(_ animation: Animation?, _ changes: @escaping () -> Void) {
        if let animation {
            withAnimation(animation, changes)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, changes)
        }
    }

    private func measureReservedWidth() -> CGFloat {
        Self.titles.map { measure(title: $0).width }.max() ?? 0
    }

    /// 文字を入れたカプセルの大きさ。フォローを変えている途中のインジケータの分も含める。
    private func measure(title: String) -> CGSize {
        // 測るホストは画面に置かないので、表示先の文字の大きさを渡す。渡さないと、表示先だけ大きさを変えているときに測った幅と合わない。
        let measuring = UIHostingController(rootView: ProfileFollowButtonLabel(
            title: title,
            reservedTitle: nil,
            showsLeadingActivity: true,
            foreground: .clear,
            contentInsets: model.contentInsets,
            imagePadding: model.imagePadding
        ).environment(\.dynamicTypeSize, DynamicTypeSize(traitCollection.preferredContentSizeCategory) ?? .large))
        measuring.view.backgroundColor = .clear
        let size = measuring.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func colors(for style: Style) -> ProfileFollowButtonColors {
        var configuration: UIButton.Configuration = switch style {
        case .filled: .filled()
        case .tinted: .tinted()
        case .gray: .gray()
        }
        if style == .filled, let filledColors {
            configuration.baseBackgroundColor = filledColors.fill
        }
        colorSource.tintColor = tintColor
        colorSource.traitOverrides.userInterfaceStyle = traitCollection.userInterfaceStyle
        colorSource.traitOverrides.accessibilityContrast = traitCollection.accessibilityContrast
        let background = configuration.updated(for: colorSource).background.backgroundColor ?? .clear
        // 標準の形の文字の色。塗りつぶしは白、ティントはティントカラー、灰色は本文の色で描く。
        let foreground: UIColor = switch style {
        case .filled: filledColors?.foreground ?? .white
        case .tinted: tintColor
        case .gray: .label
        }
        return ProfileFollowButtonColors(background: Color(uiColor: background), foreground: Color(uiColor: foreground))
    }
}

struct ProfileFollowButtonColors: Equatable {
    var background: Color
    var foreground: Color
}

@MainActor
@Observable
final class ProfileFollowButtonModel {
    var state = ProfileFollowButton.State(title: "", style: .gray)
    var colors = ProfileFollowButtonColors(background: .clear, foreground: .clear)
    var contentInsets = NSDirectionalEdgeInsets()
    var imagePadding: CGFloat = 0
    /// 描いているカプセルの幅。触れたものを受ける範囲に使う。
    var capsuleWidth: CGFloat = 0
    var onTap: () -> Void = {}
}

private struct ProfileFollowButtonView: View {
    let model: ProfileFollowButtonModel

    var body: some View {
        let state = model.state
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: model.onTap) {
                // 関係を読む前は、文字を空にして、見えない文字で幅だけ取る。届いたときに、空から届いた文字へ入れ替わるようにするため。
                // 透明な文字を入れておくと、前後に共通する文字は色が付くだけで、残りの文字だけが入れ替わって見える。
                ProfileFollowButtonLabel(
                    title: state.isPlaceholder ? "" : state.title,
                    reservedTitle: state.isPlaceholder ? state.title : nil,
                    showsLeadingActivity: state.isChanging,
                    foreground: model.colors.foreground,
                    contentInsets: model.contentInsets,
                    imagePadding: model.imagePadding
                )
                .background(Capsule().fill(model.colors.background))
                // フォローを変え始めたときと終えたときは、インジケータの出入りとカプセルの伸び縮みが同時に進む。
                // 切り抜かないと、縮むカプセルの外に消えかけのインジケータが残って見える。
                .clipShape(Capsule())
                .overlay {
                    if state.isPlaceholder, state.showsActivity {
                        ProgressView()
                            .transition(.opacity)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.capsuleWidth = $0 }
            }
            .buttonStyle(.plain)
            .disabled(state.isChanging)
            // 関係を読む前は、押せない見た目にすると下地が薄くなるため、見た目はそのままで触れないだけにする。
            .allowsHitTesting(!state.isPlaceholder)
            .accessibilityLabel(state.isPlaceholder ? "フォローの状態を読み込み中" : state.title)
            // 押せない見た目にしない代わりに、VoiceOverには押せるボタンとして示さず、文字として読ませる。
            .accessibilityRemoveTraits(state.isPlaceholder ? .isButton : [])
            .accessibilityAddTraits(state.isPlaceholder ? .isStaticText : [])
        }
        .frame(maxHeight: .infinity)
    }
}

/// カプセルの中身。枠の幅を測るときにも使う。
private struct ProfileFollowButtonLabel: View {
    let title: String
    /// 見せずに幅と高さだけを取る文字。
    let reservedTitle: String?
    let showsLeadingActivity: Bool
    let foreground: Color
    let contentInsets: NSDirectionalEdgeInsets
    let imagePadding: CGFloat

    var body: some View {
        HStack(spacing: imagePadding) {
            if showsLeadingActivity {
                ProgressView()
                    .tint(foreground)
                    .transition(.opacity)
            }
            ZStack {
                if let reservedTitle {
                    Text(reservedTitle)
                        .font(.body)
                        .lineLimit(1)
                        .hidden()
                }
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(foreground)
                    .contentTransition(.numericText())
            }
        }
        .padding(EdgeInsets(top: contentInsets.top, leading: contentInsets.leading, bottom: contentInsets.bottom, trailing: contentInsets.trailing))
    }
}
