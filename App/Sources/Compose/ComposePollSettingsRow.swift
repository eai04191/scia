import SciaCore
import SwiftUI
import UIKit

/// 投票の欄の切り替えのボタンの文言を、設定の行の幅に合わせて縮める段階。
enum SettingsLabelLength: CaseIterable {
    /// 「1つ選ぶ」「結果を表示」
    case full
    /// 結果のボタンだけ「表示」に縮める。
    case shortResults
    /// 選び方のボタンも「1つ」に縮める。
    case shortBoth

    typealias Label = (title: String, symbolName: String)

    static func multipleLabels(short: Bool) -> (off: Label, on: Label) {
        short ? (("1つ", "checklist"), ("複数", "checklist.checked")) : (("1つ選ぶ", "checklist"), ("複数選ぶ", "checklist.checked"))
    }

    static func hidesTotalsLabels(short: Bool) -> (off: Label, on: Label) {
        short ? (("表示", "eye"), ("隠す", "eye.slash")) : (("結果を表示", "eye"), ("結果を隠す", "eye.slash"))
    }
}

/// 設定の行に出す値。
struct ComposePollSettings: Equatable {
    var expiresIn = 86_400
    var multiple = false
    var hidesTotals = false
    /// 選べる締め切り。
    var expiryChoices: [Int] = []
}

/// 投稿欄の投票の欄の、設定の1行。締め切り、選び方、結果を見せるかの3つのボタンと、投票を外すボタンを並べる。
///
/// 値が替わるときに、締め切りは替わる文字だけを入れ替え（`numericText`）、
/// 文字の長さで変わるボタンの幅と位置を同じスプリングで動かすため、SwiftUIで描いて投票の欄に載せる。
/// 切り替えのアイコンと文字は動かさずに替える。同じ場所で2つの文言を重ねて入れ替えると、途中が読めない二重の文字になるため。
///
/// 文言を縮める段階は、SwiftUIの並べ直しを待たずに、行の幅と段階ごとの幅を比べてここで決める。値を替える動きの中で段階も一緒に替えるため。
@MainActor
final class ComposePollSettingsRow: UIView {
    var onSetExpiry: (Int) -> Void = { _ in }
    var onSetMultiple: (Bool) -> Void = { _ in }
    var onSetHidesTotals: (Bool) -> Void = { _ in }
    var onRemovePoll: () -> Void = {}

    /// 切り替えのボタンの文言を、行に収まるところまで縮めた段階。
    var labelLength: SettingsLabelLength { model.labelLength }
    private(set) var settings = ComposePollSettings()

    private let model = ComposePollSettingsModel()
    private lazy var hosting = UIHostingController(rootView: ComposePollSettingsView(model: model))
    /// 段階ごとの幅と行の高さを測るホスト。画面には置かない。
    private lazy var measuring = UIHostingController(rootView: AnyView(EmptyView()))
    /// 灰色のボタンの標準の地の色を、見た目のモードに合わせて読むためのボタン。画面には置かない。
    private let colorSource = UIButton(configuration: .gray())
    /// 測った、段階ごとの行の幅と、行の高さ。締め切りの文字か文字の大きさが変わったら測り直す。
    private var fitting: (widths: [(length: SettingsLabelLength, width: CGFloat)], height: CGFloat)?
    /// 最後に段階を決めた幅。
    private var labelLengthWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        model.onSetExpiry = { [weak self] in self?.onSetExpiry($0) }
        model.onSetMultiple = { [weak self] in self?.onSetMultiple($0) }
        model.onSetHidesTotals = { [weak self] in self?.onSetHidesTotals($0) }
        model.onRemovePoll = { [weak self] in self?.onRemovePoll() }
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // 高さはここで測って決め、キーボードや画面の端の安全領域で中身を動かさない。
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ComposePollSettingsRow, _) in
            view.refreshColors()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ComposePollSettingsRow, _) in
            view.invalidateFitting()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter duration: 値と、文字の長さで変わるボタンの幅を変える時間。0なら、すぐ変える。
    func apply(_ settings: ComposePollSettings, duration: TimeInterval) {
        guard settings != self.settings else { return }
        let expiryChanged = settings.expiresIn != self.settings.expiresIn
        self.settings = settings
        if expiryChanged {
            fitting = nil
        }
        let changes = {
            self.model.settings = settings
            self.updateLabelLength()
        }
        if duration > 0 {
            withAnimation(.smooth(duration: duration), changes)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, changes)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredFitting().height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != labelLengthWidth else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { updateLabelLength() }
    }

    /// 行を今の幅に収める段階を決める。結果のボタンを先に縮める。行のいちばん後ろにあり、幅が足りないと「結果を…」と切れて、表示するか隠すかが読めなくなったため。
    /// 目のアイコンが結果を表すので、「表示」「隠す」だけでも通じる。どの段階でも収まらなければ、いちばん短い文言にして、残りは行末をぼかして切る。
    private func updateLabelLength() {
        guard bounds.width > 0 else { return }
        labelLengthWidth = bounds.width
        let widths = measuredFitting().widths
        let length = widths.first { $0.width <= bounds.width }?.length
        if model.labelLength != length ?? .shortBoth {
            model.labelLength = length ?? .shortBoth
        }
        if model.isTruncated != (length == nil) {
            model.isTruncated = length == nil
        }
    }

    private func invalidateFitting() {
        fitting = nil
        labelLengthWidth = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 段階ごとの、切らずに並べた行の幅と、行の高さ。切り替えのボタンは、2つの値の長いほうで測る。押して文言が替わっただけで、段階が切り替わらないようにするため。
    private func measuredFitting() -> (widths: [(length: SettingsLabelLength, width: CGFloat)], height: CGFloat) {
        if let fitting {
            return fitting
        }
        let size = DynamicTypeSize(traitCollection.preferredContentSizeCategory) ?? .large
        var height: CGFloat = 0
        let widths = SettingsLabelLength.allCases.map { length in
            // 測るホストは画面に置かないので、表示先の文字の大きさを渡す。
            measuring.rootView = AnyView(
                ComposePollSettingsContent(settings: settings, length: length, isTruncated: false, colors: model.colors, reservesBothValues: true, actions: nil)
                    .environment(\.dynamicTypeSize, size)
            )
            let fitted = measuring.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            height = max(height, ceil(fitted.height))
            return (length: length, width: ceil(fitted.width))
        }
        let fitting = (widths: widths, height: height)
        self.fitting = fitting
        return fitting
    }

    private func refreshColors() {
        colorSource.traitOverrides.userInterfaceStyle = traitCollection.userInterfaceStyle
        colorSource.traitOverrides.accessibilityContrast = traitCollection.accessibilityContrast
        let background = UIButton.Configuration.gray().updated(for: colorSource).background.backgroundColor ?? .tertiarySystemFill
        let colors = ComposePollSettingsColors(background: Color(uiColor: background), foreground: Color(uiColor: .label))
        guard colors != model.colors else { return }
        model.colors = colors
    }
}

struct ComposePollSettingsColors: Equatable {
    var background = Color.clear
    var foreground = Color.primary
}

@MainActor
@Observable
final class ComposePollSettingsModel {
    var settings = ComposePollSettings()
    var labelLength = SettingsLabelLength.full
    /// いちばん短い文言でも行に収まらず、切り替えのボタンの行末をぼかして切っている。
    var isTruncated = false
    var colors = ComposePollSettingsColors()
    @ObservationIgnored var onSetExpiry: (Int) -> Void = { _ in }
    @ObservationIgnored var onSetMultiple: (Bool) -> Void = { _ in }
    @ObservationIgnored var onSetHidesTotals: (Bool) -> Void = { _ in }
    @ObservationIgnored var onRemovePoll: () -> Void = {}
}

private struct ComposePollSettingsView: View {
    let model: ComposePollSettingsModel

    var body: some View {
        ComposePollSettingsContent(
            settings: model.settings,
            length: model.labelLength,
            isTruncated: model.isTruncated,
            colors: model.colors,
            reservesBothValues: false,
            actions: model
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 設定の行の中身。段階ごとの幅を測るときにも使う。
private struct ComposePollSettingsContent: View {
    let settings: ComposePollSettings
    let length: SettingsLabelLength
    let isTruncated: Bool
    let colors: ComposePollSettingsColors
    /// 結果のボタンも、2つの値の長いほうの幅を取る。幅を測るときに使う。
    let reservesBothValues: Bool
    /// 押したときの処理。nilなら、幅を測るだけで押せない。
    let actions: ComposePollSettingsModel?

    var body: some View {
        let multiple = SettingsLabelLength.multipleLabels(short: length == .shortBoth)
        let hidesTotals = SettingsLabelLength.hidesTotalsLabels(short: length != .full)
        let expiry = PollDraft.expiryTitle(settings.expiresIn)
        HStack(spacing: 6) {
            Menu {
                Picker("締め切り", selection: Binding(get: { settings.expiresIn }, set: { actions?.onSetExpiry($0) })) {
                    ForEach(settings.expiryChoices, id: \.self) { seconds in
                        Text(PollDraft.expiryTitle(seconds)).tag(seconds)
                    }
                }
            } label: {
                chip(symbolName: "clock") {
                    Text(expiry)
                        .contentTransition(.numericText())
                }
            }
            // 締め切りは「1日」のように短く、切ると値が読めなくなるため、幅が足りなければ切り替えのボタンの文字を切る。
            .layoutPriority(1)
            .accessibilityLabel("締め切り")
            .accessibilityValue(expiry)

            // 押すとラベルの長さが変わり、右隣の結果のボタンがずれるため、選び方のボタンは2つの値の長いほうに幅を合わせる。
            // 結果のボタンは合わせない。右は空きで、幅が変わっても動くものがなく、揃えると「隠す」の両側に余白が目立ったため。
            toggle(value: settings.multiple, labels: multiple, reservesBothValues: true) {
                actions?.onSetMultiple(!settings.multiple)
            }
            .accessibilityLabel("選び方")
            .accessibilityValue(settings.multiple ? "複数選ぶ" : "1つ選ぶ")

            toggle(value: settings.hidesTotals, labels: hidesTotals, reservesBothValues: reservesBothValues) {
                actions?.onSetHidesTotals(!settings.hidesTotals)
            }
            .accessibilityLabel("結果")
            .accessibilityValue(settings.hidesTotals ? "結果を隠す" : "結果を表示")
            .accessibilityHint(settings.hidesTotals ? "投票した人に票数を表示します。" : "締め切るまで票数を隠します。")

            Spacer(minLength: 0)

            Button {
                actions?.onRemovePoll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(minWidth: 25, minHeight: 25)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("投票を外す")
        }
    }

    /// 今の設定をラベルに出す切り替えのボタン。締め切りのボタンと同じく、どちらの値でも同じ灰色で描く。
    private func toggle(value: Bool, labels: (off: SettingsLabelLength.Label, on: SettingsLabelLength.Label), reservesBothValues: Bool, action: @escaping () -> Void) -> some View {
        let label = value ? labels.on : labels.off
        return Button(action: action) {
            chip(symbolName: label.symbolName) {
                ZStack(alignment: .leading) {
                    if reservesBothValues {
                        Text(labels.off.title).hidden()
                        Text(labels.on.title).hidden()
                    }
                    Text(label.title)
                        .contentTransition(.identity)
                }
                .fixedSize()
                // 幅が足りなければ、文字を「…」で切らずに、行末をぼかして切る。
                .frame(minWidth: 0, alignment: .leading)
                .clipped()
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        if isTruncated {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 16)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func chip(symbolName: String, @ViewBuilder title: () -> some View) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .imageScale(.large)
                // 行の高さは文字で決める。アイコンは文字より背が高く、アイコンによって高さも違うため。
                .frame(height: 0)
                // アイコンを替えるときは動かさない。`contentTransition(.identity)`だけでは、設定を変える動きの中で前のアイコンと重なって入れ替わる。
                .transaction(value: symbolName) { $0.animation = nil }
            title()
                .lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(colors.foreground)
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        .background(Capsule().fill(colors.background))
        .contentShape(Capsule())
    }
}
