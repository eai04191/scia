import SciaCore
import SwiftUI
import UIKit

/// 「投稿の見た目」。上にプレビューを固定し、下に投稿の部品ごとの分類を、投稿の上から下への並びで置く。
/// 分類を押すと、その分類の画面（`AppearanceGroupEditorView`）を重ねる。決まりはdocs/appearance.mdにある。
struct AppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var samples: AppearanceSamples
    /// 開いたときに重ねておく分類の画面。
    @State private var opened: AppearanceGroup.ID?
    @State private var confirmsReset = false
    /// すべて既定に戻した回数。戻すと値がまとめて変わるので、プレビューの高さを合わせ直す。
    @State private var resets = 0
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameter group: 開いたときに重ねておく分類の画面。
    init(settings: AppSettings, opening group: AppearanceGroup.ID? = nil, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        _samples = State(initialValue: AppearanceSamples(settings: settings, tuning: tuning, now: now()))
        _opened = State(initialValue: group)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(colorScheme: colorScheme, groups: []),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit,
                    fitRevision: resets
                )
                Divider()
                Form {
                    Section {
                        ForEach(groups) { group in
                            NavigationLink {
                                AppearanceGroupEditorView(group: group, settings: settings)
                            } label: {
                                GroupLabel(title: group.title, isModified: group.values.contains(where: settings.isModified))
                            }
                        }
                    }
                    Section {
                        Button("すべて既定に戻す", role: .destructive) { confirmsReset = true }
                            .disabled(!settings.isAppearanceModified)
                    } footer: {
                        Text("文字の大きさはiPhoneの文字サイズが標準のときの大きさです。本文はiPhoneの文字サイズに合わせて伸び縮みし、ほかの文字は本文との差を保ちます。")
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { id in
            if let group = groups.first(where: { $0.id == id }) {
                AppearanceGroupEditorView(group: group, settings: settings)
            }
        }
        .navigationTitle("投稿")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("投稿の見た目をすべて既定に戻しますか？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("既定に戻す", role: .destructive) {
                settings.resetAppearance()
                resets += 1
            }
        }
    }

    private var groups: [AppearanceGroup] {
        AppearanceCatalog.groups
    }
}

/// 「投稿の見た目」の、1つの分類の画面。上にその分類の見本を固定し、下にその分類の項目を置く。
/// 最後に触った項目にしか要らない見本は、触っている間だけプレビューに足す。
struct AppearanceGroupEditorView: View {
    let group: AppearanceGroup
    @Bindable var settings: AppSettings
    @State private var samples: AppearanceSamples
    /// 最後に触った項目。
    @State private var focused: AppearanceFocus?
    @Environment(\.colorScheme) private var colorScheme

    init(group: AppearanceGroup, settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.group = group
        self.settings = settings
        _samples = State(initialValue: AppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(colorScheme: previewColorScheme, groups: [group.id], focus: focused),
                    interfaceStyle: focused?.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified,
                    heightLimit: geometry.size.height * Self.previewHeightLimit
                )
                Divider()
                Form {
                    // 選んで決める項目のない分類では、中身のないセクションは描かれない。
                    Section {
                        choices(of: group)
                    }
                    Section {
                        ForEach(group.values) { item in
                            AppearanceValueRow(
                                item: item,
                                settings: settings,
                                isFocused: focused == .value(item),
                                onFocus: { focused = .value(item) },
                                onToggleFocus: { toggleFocus(.value(item)) }
                            )
                            .disabled(isUnused(item))
                        }
                    }
                }
                // スイッチは押すとすぐ切り替わるので、切り替えたときに触っている項目にする。メニューで選ぶ項目は、メニューを開いたときにする。
                .onChange(of: settings.appearance.showsBoosterAvatar) { focused = .choice(.showsBoosterAvatar) }
                .onChange(of: settings.appearance.showsContextSymbol) { focused = .choice(.showsContextSymbol) }
                .onChange(of: settings.appearance.boldsName) { focused = .choice(.boldsName) }
                .onChange(of: settings.appearance.showsAvatarBorder) { focused = .choice(.showsAvatarBorder) }
                .onChange(of: settings.appearance.showsMediaBadges) { focused = .choice(.showsMediaBadges) }
                .onChange(of: settings.appearance.tiltsStackedPhotos) { focused = .choice(.tiltsStackedPhotos) }
                .onChange(of: settings.appearance.showsLinkCard) { focused = .choice(.showsLinkCard) }
                .onChange(of: settings.appearance.boldsLinkCardTitle) { focused = .choice(.boldsLinkCardTitle) }
                .onChange(of: settings.appearance.showsSeparators) { focused = .choice(.showsSeparators) }
                .onChange(of: settings.appearance.showsReplyLabel) { focused = .choice(.showsReplyLabel) }
                .onChange(of: settings.appearance.showsReplyLines) { focused = .choice(.showsReplyLines) }
                .onChange(of: settings.appearance.wrapsBelowAvatar) { focused = .choice(.wrapsBelowAvatar) }
                .onChange(of: settings.appearance.stacksNameParts) { focused = .choice(.stacksNameParts) }
                .onChange(of: settings.appearance.showsTime) { focused = .choice(.showsTime) }
                .onChange(of: settings.appearance.showsVisibilitySymbol) { focused = .choice(.showsVisibilitySymbol) }
                .onChange(of: settings.appearance.showsEditedMark) { focused = .choice(.showsEditedMark) }
                .onChange(of: settings.appearance.showsLinkCardSite) { focused = .choice(.showsLinkCardSite) }
                .onChange(of: settings.appearance.showsLinkCardImage) { focused = .choice(.showsLinkCardImage) }
                .onChange(of: settings.appearance.animatesAvatars) { focused = .choice(.animatesAvatars) }
                .onChange(of: settings.appearance.animatesCustomEmojis) { focused = .choice(.animatesCustomEmojis) }
                .onChange(of: settings.appearance.drawsReactionGlowInHDR) { focused = .choice(.drawsReactionGlowInHDR) }
                .onChange(of: settings.appearance.reactionGlowFillsWidthWhenAlone) { focused = .choice(.reactionGlowFillsWidthWhenAlone) }
            }
        }
        .toolbar {
            // 数字のキーボードには確定のキーがないため、閉じて打った値を確定するボタンを置く。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 見本の高さの上限。画面の高さに対する割合。
    static let previewHeightLimit: CGFloat = 0.42

    /// 見本を描く外観。外観ごとにしか効かない項目を触っている間は、その外観で描く。端末と違う外観の項目では、値を変えても見た目が変わらないため。
    private var previewColorScheme: ColorScheme {
        focused?.colorScheme ?? colorScheme
    }

    /// 項目の名前をタップしたとき、その項目を触っている項目にする。触っている項目なら、やめる。
    private func toggleFocus(_ focus: AppearanceFocus) {
        focused = focused == focus ? nil : focus
    }

    /// 数値ではなく選んで決める項目。その部品の項目の先頭に置く。
    @ViewBuilder
    private func choices(of group: AppearanceGroup) -> some View {
        switch group.id {
        case "row":
            TitledToggleRow(title: "投稿のあいだに区切り線を引く", isOn: $settings.appearance.showsSeparators) { toggleFocus(.choice(.showsSeparators)) }
        case "context":
            PopUpChoiceRow(title: "ブーストした人の表記", selection: $settings.appearance.contextNameStyle, options: Self.nameStyles, onOpen: { focus(.contextNameStyle) }, onTapTitle: { toggleFocus(.choice(.contextNameStyle)) })
            TitledToggleRow(title: "ブーストや返信の記号を出す", isOn: $settings.appearance.showsContextSymbol) { toggleFocus(.choice(.showsContextSymbol)) }
            TitledToggleRow(title: "ブーストした人のアイコンを出す", isOn: $settings.appearance.showsBoosterAvatar) { toggleFocus(.choice(.showsBoosterAvatar)) }
            TitledToggleRow(title: "返信のラベルを出す", isOn: $settings.appearance.showsReplyLabel) { toggleFocus(.choice(.showsReplyLabel)) }
        case "avatar":
            PopUpChoiceRow(title: "形", selection: $settings.appearance.avatarShape, options: [(.circle, "円"), (.roundedSquare, "角丸の四角")], onOpen: { focus(.avatarShape) }, onTapTitle: { toggleFocus(.choice(.avatarShape)) })
            TitledToggleRow(title: "縁取りを出す", isOn: $settings.appearance.showsAvatarBorder) { toggleFocus(.choice(.showsAvatarBorder)) }
            TitledToggleRow(title: "アニメーションを再生する", isOn: $settings.animatesAvatars) { toggleFocus(.choice(.animatesAvatars)) }
            TitledToggleRow(title: "アイコンの下を空けない", isOn: $settings.appearance.wrapsBelowAvatar) { toggleFocus(.choice(.wrapsBelowAvatar)) }
            // アイコンの下を空けないときは、線の通る場所に本文などが入るので、線を出さない。
            TitledToggleRow(title: "返信をつなぐ線を出す", isOn: $settings.appearance.showsReplyLines) { toggleFocus(.choice(.showsReplyLines)) }
                .disabled(settings.appearance.wrapsBelowAvatar)
        case "name":
            PopUpChoiceRow(title: "名前の表記", selection: $settings.appearance.statusNameStyle, options: Self.nameStyles, onOpen: { focus(.nameStyle) }, onTapTitle: { toggleFocus(.choice(.nameStyle)) })
            TitledToggleRow(title: "名前とハンドルを2段に分ける", isOn: $settings.appearance.stacksNameParts) { toggleFocus(.choice(.stacksNameParts)) }
                .disabled(settings.appearance.statusNameStyle.parts.count < 2)
            PopUpChoiceRow(title: "時刻の表記", selection: $settings.appearance.statusTimeStyle, options: [(.relative, "相対時刻"), (.absolute, "日時")], onOpen: { focus(.timeStyle) }, onTapTitle: { toggleFocus(.choice(.timeStyle)) })
            TitledToggleRow(title: "名前を太字にする", isOn: $settings.appearance.boldsName) { toggleFocus(.choice(.boldsName)) }
            TitledToggleRow(title: "時刻を出す", isOn: $settings.appearance.showsTime) { toggleFocus(.choice(.showsTime)) }
            TitledToggleRow(title: "公開範囲の記号を出す", isOn: $settings.appearance.showsVisibilitySymbol) { toggleFocus(.choice(.showsVisibilitySymbol)) }
            TitledToggleRow(title: "編集済みの「*」を出す", isOn: $settings.appearance.showsEditedMark) { toggleFocus(.choice(.showsEditedMark)) }
        case "body":
            PopUpChoiceRow(
                title: "漢字の字形",
                selection: $settings.appearance.glyphLanguage,
                options: [(.automatic, "自動"), (.japanese, "日本語"), (.simplifiedChinese, "簡体字中国語"), (.traditionalChinese, "繁体字中国語"), (.korean, "韓国語")]
            , onOpen: { focus(.glyphLanguage) }, onTapTitle: { toggleFocus(.choice(.glyphLanguage)) })
            PopUpChoiceRow(title: "絵文字", selection: $settings.appearance.emojiStyle, options: [(.system, "Apple"), (.twemoji, "Twemoji")], onOpen: { focus(.emojiStyle) }, onTapTitle: { toggleFocus(.choice(.emojiStyle)) })
            TitledToggleRow(title: "カスタム絵文字のアニメーションを再生する", isOn: $settings.animatesCustomEmojis) { toggleFocus(.choice(.animatesCustomEmojis)) }
        case "media":
            PopUpChoiceRow(title: "並べ方", selection: $settings.appearance.mediaArrangement, options: [(.belowBody, "本文の下に大きく"), (.besideBody, "本文の右に小さく")], onOpen: { focus(.mediaArrangement) }, onTapTitle: { toggleFocus(.choice(.mediaArrangement)) })
            PopUpChoiceRow(title: "引用", selection: $settings.appearance.embedMediaArrangement, options: [(.sameAsPost, "投稿と同じ"), (.besideBody, "本文の右に小さく"), (.belowBody, "本文の下に大きく")], onOpen: { focus(.embedMediaArrangement) }, onTapTitle: { toggleFocus(.choice(.embedMediaArrangement)) })
            TitledToggleRow(title: "写真を傾ける", isOn: $settings.appearance.tiltsStackedPhotos) { toggleFocus(.choice(.tiltsStackedPhotos)) }
                .disabled(!settings.appearance.stacksMediaBesideBody)
            TitledToggleRow(title: "ALTやGIFのバッジを出す", isOn: $settings.appearance.showsMediaBadges) { toggleFocus(.choice(.showsMediaBadges)) }
        case "linkCard":
            TitledToggleRow(title: "リンクカードを出す", isOn: $settings.appearance.showsLinkCard) { toggleFocus(.choice(.showsLinkCard)) }
            TitledToggleRow(title: "タイトルを太字にする", isOn: $settings.appearance.boldsLinkCardTitle) { toggleFocus(.choice(.boldsLinkCardTitle)) }
            TitledToggleRow(title: "画像を出す", isOn: $settings.appearance.showsLinkCardImage) { toggleFocus(.choice(.showsLinkCardImage)) }
            PopUpChoiceRow(title: "画像の位置", selection: $settings.appearance.linkCardThumbnailSide, options: [(.left, "左"), (.right, "右")], onOpen: { focus(.linkCardThumbnailSide) }, onTapTitle: { toggleFocus(.choice(.linkCardThumbnailSide)) })
                .disabled(!settings.appearance.showsLinkCardImage)
            TitledToggleRow(title: "サイト名を出す", isOn: $settings.appearance.showsLinkCardSite) { toggleFocus(.choice(.showsLinkCardSite)) }
        case "reactionGlow":
            // HDRのメディアの明るさの設定はメディアに対するものなので、光はそれに従わせず、ここで別に選ぶ。
            if ReactionGlowView.mayDrawInHDR {
                TitledToggleRow(title: "HDRに対応した画面では白より明るく光らせる", isOn: $settings.appearance.drawsReactionGlowInHDR) { toggleFocus(.choice(.drawsReactionGlowInHDR)) }
            }
            PopUpChoiceRow(title: "アイコン", selection: $settings.appearance.reactionGlowIcons, options: [(.none, "出さない"), (.atBottom, "下の端に1つずつ"), (.scattered, "散らす")], onOpen: { focus(.reactionGlowIcons) }, onTapTitle: { toggleFocus(.choice(.reactionGlowIcons)) })
            TitledToggleRow(title: "片方だけのときは全幅を光らせる", isOn: $settings.appearance.reactionGlowFillsWidthWhenAlone) { toggleFocus(.choice(.reactionGlowFillsWidthWhenAlone)) }
            PopUpChoiceRow(title: "ライトモードのお気に入りの色", selection: $settings.appearance.reactionGlowLightFavouriteColor, options: [(.orange, "橙"), (.yellow, "黄色")], onOpen: { focus(.reactionGlowLightFavouriteColor) }, onTapTitle: { toggleFocus(.choice(.reactionGlowLightFavouriteColor)) })
        default:
            EmptyView()
        }
    }

    /// ほかの選択肢のために、見た目に効かない項目。光のアイコンを出さないときの、アイコンの大きさと濃さ。
    private func isUnused(_ item: AppearanceValue) -> Bool {
        settings.appearance.reactionGlowIcons == .none && [AppearanceCatalog.reactionGlowIconSize, AppearanceCatalog.reactionGlowIconOpacity].contains(item)
    }

    /// 選択肢のメニューを開いたときに、その場所を示す。選んで閉じても示したままにする。
    private func focus(_ choice: AppearanceChoice) {
        focused = .choice(choice)
    }

    private static let nameStyles: [(value: StatusNameStyle, title: String)] = [
        (.nameAndAcct, "名前、ハンドル"),
        (.nameOnly, "名前"),
        (.acctOnly, "ハンドル"),
        (.acctAndName, "ハンドル、名前"),
    ]
}

/// 「投稿の見た目」で、最後に触った項目。
enum AppearanceFocus: Hashable {
    case value(AppearanceValue)
    case choice(AppearanceChoice)

    /// この項目が効く外観。どちらの外観でも効く項目はnil。
    var colorScheme: ColorScheme? {
        switch self {
        case .value(AppearanceCatalog.reactionGlowDarkOpacity): .dark
        case .value(AppearanceCatalog.reactionGlowLightOpacity), .choice(.reactionGlowLightFavouriteColor): .light
        default: nil
        }
    }
}

/// 数値ではなく選んで決める項目。
enum AppearanceChoice: Hashable, CaseIterable {
    case contextNameStyle
    case showsContextSymbol
    case boldsName
    case showsAvatarBorder
    case showsMediaBadges
    case showsLinkCard
    case boldsLinkCardTitle
    case showsSeparators
    case showsBoosterAvatar
    case showsReplyLabel
    case showsReplyLines
    case wrapsBelowAvatar
    case stacksNameParts
    case showsTime
    case showsLinkCardImage
    case showsVisibilitySymbol
    case showsEditedMark
    case showsLinkCardSite
    case avatarShape
    case animatesAvatars
    case nameStyle
    case timeStyle
    case glyphLanguage
    case emojiStyle
    case animatesCustomEmojis
    case linkCardThumbnailSide
    case mediaArrangement
    case embedMediaArrangement
    case tiltsStackedPhotos
    case drawsReactionGlowInHDR
    case reactionGlowIcons
    case reactionGlowFillsWidthWhenAlone
    case reactionGlowLightFavouriteColor

    var highlight: AppearanceHighlight {
        switch self {
        case .contextNameStyle: .part(.boostLine)
        case .showsContextSymbol: .part(.contextSymbolSlot)
        case .boldsName: .part(.namePrimary)
        case .showsAvatarBorder: .part(.avatar)
        case .showsMediaBadges: .part(.mediaBadgeSlot)
        case .showsLinkCard: .firstOf([.part(.card), .part(.cardSlot)])
        case .boldsLinkCardTitle: .firstPart([.cardTitle, .card])
        case .showsSeparators: .part(.separatorLine)
        case .showsBoosterAvatar: .part(.boosterAvatarSlot)
        case .showsReplyLabel: .part(.replyLabelSlot)
        case .showsReplyLines: .part(.replyLineSlot)
        case .wrapsBelowAvatar: .firstOf([.part(.postHeader), .part(.avatar)])
        case .stacksNameParts: .firstOf([.part(.nameGlyphs), .part(.nameRow)])
        case .showsTime: .part(.timeSlot)
        case .showsLinkCardImage: .part(.cardImageSlot)
        case .showsVisibilitySymbol: .part(.visibilitySymbol)
        case .showsEditedMark: .part(.editedMark)
        case .showsLinkCardSite: .part(.cardSiteSlot)
        case .avatarShape, .animatesAvatars: .part(.avatar)
        case .nameStyle: .part(.nameRow)
        case .timeStyle: .firstOf([.part(.time), .part(.timeSlot)])
        // 字形と絵文字は、名前、名前の上の行、注意書き、本文のどれにも効くので、行の中のそれらをすべて示す。
        case .glyphLanguage, .emojiStyle: .allParts([.contextLine, .namePrimary, .nameSecondary, .spoilerText, .bodyText])
        case .animatesCustomEmojis: .firstOf([.part(.customEmojis), .part(.bodyText)])
        case .linkCardThumbnailSide: .part(.card)
        case .mediaArrangement: .firstOf([.part(.besideMedia), .part(.media)])
        // 引用とXの投稿だけを右に出すときは、囲みの中の写真を示す。
        case .tiltsStackedPhotos: .firstOf([.part(.besideMedia), .part(.xPostBesideMedia), .part(.media)])
        case .embedMediaArrangement: .firstOf([.part(.xPostBesideMedia), .part(.xPostMedia)])
        case .drawsReactionGlowInHDR, .reactionGlowLightFavouriteColor: .part(.reactionGlow)
        case .reactionGlowFillsWidthWhenAlone: .firstOf([.part(.reactionGlowAlone), .part(.reactionGlow)])
        case .reactionGlowIcons: .firstOf([.part(.reactionGlowIcons), .part(.reactionGlow)])
        }
    }
}

/// 部品の見出し。既定値から変えた項目があれば、印を添える。
struct GroupLabel: View {
    let title: String
    let isModified: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if isModified {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("変更あり")
            }
        }
    }
}

/// 数値の項目の1行。値はステッパーで1刻みずつ変える。スライダーより、1ptの違いを合わせやすいため。
struct AppearanceValueRow: View {
    let item: AppearanceValue
    @Bindable var settings: AppSettings
    let isFocused: Bool
    /// 値を変えたときに呼ぶ。変えた項目は示し続ける。
    let onFocus: () -> Void
    /// 名前をタップしたときに呼ぶ。示していれば、示すのをやめる。
    let onToggleFocus: () -> Void
    /// 値を入力している。入力している間は、打っている文字を値の欄に出す。
    @FocusState private var isEditing: Bool
    @State private var draft = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // 印の幅は変えていなくても取っておく。値を変えて印が出たときに名前が折り返すと、行が高くなり、押しているステッパーが指の下から動くため。
                HStack(spacing: 6) {
                    Text(item.title)
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                        .opacity(settings.isModified(item) ? 1 : 0)
                        .accessibilityLabel("変更あり")
                        .accessibilityHidden(!settings.isModified(item))
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // ＋−では遠い値まで届きにくいので、値の欄に数字を直接打てるようにする。
            HStack(spacing: 2) {
                TextField(item.title, text: Binding { isEditing ? draft : numberText } set: { draft = $0 })
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 52)
                    .focused($isEditing)
                    .onChange(of: isEditing) { _, editing in
                        if editing {
                            draft = numberText
                            onFocus()
                        } else {
                            commit()
                        }
                    }
                if let unitText {
                    Text(unitText)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(item.title, value: value, in: item.range, step: item.step)
                .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleFocus)
        .contextMenu {
            Button("既定に戻す", systemImage: "arrow.uturn.backward") {
                settings.reset([item])
                onFocus()
            }
            .disabled(!settings.isModified(item))
        }
    }

    private var value: Binding<Double> {
        Binding {
            settings.value(of: item)
        } set: { newValue in
            settings.setValue(newValue, for: item)
            onFocus()
        }
    }

    private var typography: PostTypography {
        PostTypography(settings: settings)
    }

    private var role: PostTypography.Role? {
        PostTypography.Role.allCases.first { $0.setting == item }
    }

    /// 値の欄に出す数。文字の大きさは、本文との差ではなく、実際の大きさで見せる。
    private var numberText: String {
        if let role {
            return Self.format(typography.standardPointSize(role))
        }
        let value = settings.value(of: item)
        return item.unit == .ratio ? String(format: "%.2f", value) : Self.format(value)
    }

    private var unitText: String? {
        switch item.unit {
        case .ratio: nil
        case .lines: "行"
        case .count: "個"
        case .point, .bodyTextOffset, .textOffset: "pt"
        }
    }

    /// 打った数を値にする。文字の大きさは実際の大きさで打つので、本文との差に直す。範囲の外は範囲に収め、数でなければ元のままにする。
    private func commit() {
        guard let number = Double(draft.replacingOccurrences(of: ",", with: ".")) else { return }
        let newValue = role.map { Double(typography.offset(for: $0, standardPointSize: CGFloat(number))) } ?? number
        // 打ち直さずに閉じたときは、何もしない。名前のタップで示すのをやめたのを、閉じたことで示し直さないため。
        guard newValue != settings.value(of: item) else { return }
        settings.setValue(newValue, for: item)
        onFocus()
    }

    /// 文字の大きさの決まり方。本文は標準との差、ほかは本文との差。
    /// 割合の項目の、値の向きの説明。割合の意味は項目ごとに違うので、単位ではなく項目で決める。
    static func ratioNote(for item: AppearanceValue) -> String? {
        switch item.id {
        case AppearanceCatalog.mediaTallestAspectRatio.id: "小さいほど縦長のまま出す"
        case AppearanceCatalog.mediaWidestAspectRatio.id: "大きいほど横長のまま出す"
        case AppearanceCatalog.avatarCornerRatio.id: "0.5で円になる"
        case AppearanceCatalog.quoteIndent.id: "1で本文の1文字分"
        case AppearanceCatalog.linkCardImageWidthRatio.id: "画像はカードの高さの正方形より広くならない"
        // カスタム絵文字の割合の基準（普通の絵文字を文字の大きさのまま描いたときの大きさ）は見出しに書かず、1がどの大きさかで伝える。普通の絵文字は、1でいつもの大きさなのが倍率から分かるので添えない。
        case AppearanceCatalog.customEmojiScale.id, AppearanceCatalog.nameCustomEmojiScale.id: "1で絵文字と同じ大きさ"
        default: nil
        }
    }

    private var note: String? {
        let offset = settings.value(of: item)
        switch item.unit {
        case .point: return nil
        case .lines: return offset == 0 ? (item == AppearanceCatalog.bodyTruncationThreshold ? "切らない" : "出さない") : nil
        case .count: return item == AppearanceCatalog.emojiOnlyLimit && offset == 0 ? "大きくしない" : nil
        case .ratio: return Self.ratioNote(for: item)
        case .bodyTextOffset: return offset == 0 ? "標準" : "標準\(Self.signed(offset))"
        case .textOffset: return offset == 0 ? "本文と同じ" : "本文\(Self.signed(offset))"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }

    private static func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "−") + format(abs(value))
    }
}

/// プレビューに並べる見本の投稿。調整できる部品がどれかの投稿に出るように組む。決まりはdocs/appearance.mdの「プレビュー」にある。
/// 一覧（`TimelineViewController`）に並べて描き、画像は通信しないよう、アプリのアイコンから作ったものと同梱した写真を使う。
@MainActor
struct AppearanceSamples {
    /// 見本を並べる一覧。見本を組むのにも、プレビューに置いて見せるのにも使う。1つの画面に1つずつ置く。
    let timeline: TimelineViewController
    private let settings: AppSettings
    private let tuning: TuningStore
    private let now: Date
    private let posts: [Status]
    private let lightPosts: [Status]
    private let quote: Status

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        self.settings = settings
        self.tuning = tuning
        self.now = now
        timeline = .appearancePreview(texts: .home, filterContext: .home, myAccountID: Self.myAccountID, tuning: tuning, settings: settings)
        posts = Self.posts(now: now, cardImage: PreviewImages.cardURL(for: .dark))
        lightPosts = Self.posts(now: now, cardImage: PreviewImages.cardURL(for: .light))
        quote = Self.quote(now: now)
        // 注意書きの開閉と本文のあいだを見せるため、注意書きは開いておく。開いた状態は投稿のIDで持つので、外観ごとの見本で同じIDを1回だけ開く。
        for status in posts where !status.displayed.spoilerText.isEmpty {
            timeline.toggleSpoiler(of: status)
        }
    }

    /// プレビューの一覧に並べる見本。引用の囲みを出した投稿は、いつも最後に並べる。Xの投稿の囲みも同じ値で描くが、Xの投稿は設定でオンにしたときだけ出すため、見本には出さない。
    /// - Parameters:
    ///   - groups: 見本を出す分類。渡すと、その分類の見本（`sampleIDs(for:focus:)`）だけを返す。nilならすべての見本を返す。
    ///   - focus: 触っている項目。`groups`を渡したとき、その項目にしか要らない見本を足す。
    func entries(colorScheme: ColorScheme, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil) -> [TimelineEntry] {
        let shown = groups.map { Self.sampleIDs(for: $0, focus: focus, appearance: settings.appearance) }
        return ((colorScheme == .dark ? posts : lightPosts) + [quote])
            .filter { shown?.contains($0.id) ?? true }
            .map { .status($0) }
    }

    /// 見本の行の中身。一覧に並べたときと同じく、返信でつながった隣の行と線でつなぐ。テストで、見本の部品の位置を測るのに使う。
    /// - Parameter revision: 描き直しのきっかけ。中身は使わない。
    func configurations(colorScheme: ColorScheme, revision _: Int, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil) -> [PostContentConfiguration] {
        let entries = entries(colorScheme: colorScheme, groups: groups, focus: focus)
        let connections = ReplyConnection.connections(in: entries)
        return entries.compactMap { entry in
            guard case .status(let status) = entry else { return nil }
            var configuration = timeline.contentConfiguration(for: status, base: .cell())
            configuration.replyConnection = connections[entry.id] ?? ReplyConnection()
            return configuration
        }
    }

    /// 分類の見本の投稿のID。分類ごとの見本に、触っている項目にしか要らない見本を足す。分類が空なら、分類の一覧の画面に出す部品の少ない投稿を1件だけにする。
    static func sampleIDs(for groups: Set<AppearanceGroup.ID>, focus: AppearanceFocus?, appearance: AppearanceChoices) -> Set<String> {
        let names = groups.isEmpty ? ["basic"] : groups.flatMap { groupSamples[$0] ?? [] } + focusSamples(focus, appearance: appearance)
        return Set(names.map { "preview-\($0)" })
    }

    /// 分類ごとに出す見本。その分類の項目の場所を示せる、なるべく小さい投稿を選び、既定の設定では見本の枠に収まるようにする。
    /// 行の余白と区切り線は投稿のあいだの見た目なので、行には2件を出す。
    private static let groupSamples: [AppearanceGroup.ID: [String]] = [
        "row": ["basic", "next"],
        "context": ["boost-plain", "emoji-only"],
        "avatar": ["parent", "child"],
        "name": ["basic", "name"],
        "body": ["paragraphs"],
        "spoiler": ["reply"],
        "media": ["thread"],
        "linkCard": ["boost"],
        AppearanceCatalog.xPostGroupID: ["quote"],
        "poll": ["poll"],
        "reactionGlow": ["boost-plain", "wide"],
    ]

    /// 分類のうち一部の項目にしか要らない見本。上限を見せる大きい見本などは、ふだん出すと見本の枠からはみ出すので、その項目を触っている間だけ出す。
    /// 右に並べる写真にだけ効く項目は、投稿の添付ファイルを本文の下に並べ、囲みの添付ファイルだけを右に並べるときは、引用の見本で見せる。
    private static func focusSamples(_ focus: AppearanceFocus?, appearance: AppearanceChoices) -> [String] {
        let onlyEmbedIsBeside = appearance.mediaArrangement == .belowBody && appearance.resolvedEmbedMediaArrangement == .besideBody
        return switch focus {
        case .value(AppearanceCatalog.bodyTruncationThreshold), .value(AppearanceCatalog.bodyTruncatedLines): ["long"]
        case .value(AppearanceCatalog.emojiOnlyScale), .value(AppearanceCatalog.emojiOnlyLimit): ["emoji-only"]
        case .value(AppearanceCatalog.filterNoteText), .value(AppearanceCatalog.filterNoteSpacing): ["filtered"]
        case .value(AppearanceCatalog.mediaTallestAspectRatio): ["media"]
        case .value(AppearanceCatalog.mediaWidestAspectRatio): ["wide"]
        case .choice(.embedMediaArrangement): ["quote"]
        case .value(AppearanceCatalog.mediaBesideSide), .choice(.tiltsStackedPhotos): onlyEmbedIsBeside ? ["quote"] : []
        default: []
        }
    }

    private static let quoteID = "preview-quote"

    /// 投稿を引用した投稿。引用元には、囲みの中の部品が出るよう、本文と画像を付ける。
    private static func quote(now: Date) -> Status {
        let image = PreviewImages.photoURL(.wide)
        let avatar = PreviewImages.avatarURL()
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let attachment = MediaAttachment(
            id: "preview-quote-image",
            type: .image,
            url: image,
            previewUrl: image,
            // 見本の枠に収まるよう、横長の写真にする。
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_600, height: 400))
        )
        let quoted = Status(
            id: "preview-quoted",
            createdAt: now.addingTimeInterval(-3_600),
            account: scia,
            content: PreviewPhoto.credit([.wide]),
            spoilerText: "",
            url: nil,
            mediaAttachments: [attachment]
        )
        return Status(
            id: quoteID,
            createdAt: now.addingTimeInterval(-60),
            account: friend,
            content: "<p>投稿を引用した投稿です。</p>",
            spoilerText: "",
            url: nil,
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
    }

    private static let myAccountID = "preview-scia"

    private static func posts(now: Date, cardImage: URL?) -> [Status] {
        let avatar = PreviewImages.avatarURL()
        // アニメーションを再生する設定の違いを見せるため、アイコンと絵文字には色相の回るアニメーション版を付ける。
        let animated = PreviewImages.animatedAvatarURL() ?? avatar
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: animated, avatarStatic: avatar)
        // カスタム絵文字の大きさを見せるため、アプリのアイコンを絵文字にする。
        let emojis = avatar.map { [CustomEmoji(shortcode: "scia", url: animated ?? $0, staticUrl: $0)] } ?? []
        // 名前の絵文字とカスタム絵文字の大きさを見せるため、名前にも絵文字と本文と同じカスタム絵文字を付ける。
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち🌱:scia:", avatar: animated, avatarStatic: avatar, emojis: emojis)
        // 入りきらない名前の行末のぼかしを見せるため、名前の長いアカウントも用意する。
        // 名前の絵文字の大きさも同じ投稿で見せるため、名前に絵文字とカスタム絵文字を入れる。
        let longNamed = Account(id: "preview-long", username: "long", acct: "long@example.com", displayName: "とても長い名前🌱:scia:のアカウントで、名前の行に入りきりません", avatar: animated, avatarStatic: avatar, emojis: emojis)
        func photo(_ photo: PreviewPhoto, width: Int, height: Int, description: String? = nil) -> MediaAttachment {
            let url = PreviewImages.photoURL(photo)
            return MediaAttachment(
                id: photo.rawValue,
                type: .image,
                url: url,
                previewUrl: url,
                description: description,
                meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: width, height: height))
            )
        }
        // 縦長と横長の比率の上限を見せるため、縦長の写真と横長の写真を1枚ずつ出す投稿を用意する。
        let tallImage = photo(.tall, width: 1_200, height: 1_800)
        let wideImage = photo(.wide, width: 1_600, height: 400)
        // 代替テキストのバッジを見せるため、1枚には代替テキストを付ける。
        let describedImage = photo(.gridFirst, width: 800, height: 800, description: "窓辺の猫")
        let image = photo(.gridSecond, width: 800, height: 800)
        let ownFilter = FilterResult(
            filter: FilterResult.Filter(id: "preview-filter", title: "見本", context: [.home], filterAction: .warn),
            keywordMatches: ["見本"]
        )
        let card = URL(string: "https://github.com/eai04191/scia").map {
            PreviewCard(
                url: $0,
                // 行数を増やしたときの折り返しを見せるため、タイトルも説明も1行に入りきらない長さにする。
                title: "eai04191/scia: ストリーミングAPIに対応した、手触りの良いiOS向けMastodonクライアント",
                description: "ストリーミングAPIで新着が流れてくる、手触りの良いiOS向けMastodonクライアントです。読んでいる最中に新着が来ても視点が動きません。",
                type: .link,
                providerName: "GitHub",
                image: cardImage
            )
        }
        func status(_ id: String, minutes: Double, account: Account, content: String, spoiler: String = "", media: [MediaAttachment] = [], poll: Poll? = nil, card: PreviewCard? = nil, replyingTo: Account? = nil, inReplyTo: Status.ID = "preview-thread", visibility: Status.Visibility = .public, edited: Bool = false, emojis: [CustomEmoji] = [], filtered: [FilterResult] = [], favourited: Bool = false, reblogged: Bool = false) -> Status {
            Status(
                id: "preview-\(id)",
                createdAt: now.addingTimeInterval(-minutes * 60),
                account: account,
                content: content,
                spoilerText: spoiler,
                url: nil,
                mentions: replyingTo.map { [Mention(id: $0.id, username: $0.username, url: nil, acct: $0.acct)] } ?? [],
                emojis: emojis,
                mediaAttachments: media,
                visibility: visibility,
                inReplyToId: replyingTo.map { _ in inReplyTo },
                inReplyToAccountId: replyingTo?.id,
                poll: poll,
                card: card,
                filtered: filtered,
                editedAt: edited ? now : nil,
                favourited: favourited,
                reblogged: reblogged
            )
        }
        // お気に入りとブーストの光を見せるため、ブーストした投稿は、お気に入りとブーストをした投稿にする。
        let boosted = status("boosted", minutes: 30, account: friend, content: #"<p>段落の1つ目です。設定を変えるとタイムラインの投稿がこのように表示されます🎉:scia:</p><p>段落の2つ目です。<a href="https://github.com/eai04191/scia">github.com/eai04191/scia</a></p>"#, card: card, emojis: emojis, favourited: true, reblogged: true)
        let boost = Status(id: "preview-boost", createdAt: now.addingTimeInterval(-180), account: scia, content: "", spoilerText: "", url: nil, reblog: boosted)
        // 名前の上の行と光の分類の画面に出す、リンクカードのないブースト。
        let plainBoosted = status("boosted-plain", minutes: 40, account: friend, content: "<p>ブーストされた投稿です。</p>", emojis: emojis, favourited: true, reblogged: true)
        let plainBoost = Status(id: "preview-boost-plain", createdAt: now.addingTimeInterval(-240), account: scia, content: "", spoilerText: "", url: nil, reblog: plainBoosted)
        let poll = Poll(
            id: "preview-poll",
            expiresAt: now.addingTimeInterval(86_400),
            expired: false,
            multiple: false,
            votesCount: 12,
            options: [Poll.Option(title: "円", votesCount: nil), Poll.Option(title: "角丸の四角", votesCount: nil)]
        )
        return [
            // 分類の一覧の画面に出す、部品の少ない投稿。
            status("basic", minutes: 1, account: scia, content: "<p>設定を変えるとタイムラインの投稿がこのように表示されます。</p>"),
            boost,
            // 注意書きのある投稿の画像はぼかされ、サムネイル同士のすき間が見えないため、画像は注意書きのない投稿に付ける。
            status("thread", minutes: 20, account: scia, content: PreviewPhoto.credit([.gridFirst, .gridSecond]), media: [describedImage, image]),
            // 公開範囲の記号と編集済みの「*」を見せるため、未収載で編集した投稿にする。
            status("reply", minutes: 12, account: friend, content: "<p>注意書きの下の本文です。</p>", spoiler: "注意書き", replyingTo: scia, visibility: .unlisted, edited: true),
            status("media", minutes: 8, account: scia, content: PreviewPhoto.credit([.tall]), media: [tallImage]),
            // 絵文字だけの本文を見せるため、先頭にメンションの付いた、絵文字だけの返信を用意する。メンションは大きくしない。
            status("emoji-only", minutes: 7.5, account: friend, content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> 👍:scia:🎉</p>"#, replyingTo: scia, emojis: emojis),
            // 長い本文を切って「続きを読む」を出すところを見せるため、1行ずつの段落を、既定の切り始める行数より1行だけ多く並べる。
            // 切り始める行数を少し増やすと切らなくなり、値の違いが見本に出る。
            status("long", minutes: 7.2, account: scia, content: (1...33).map { "<p>長い本文の\($0)行目です。</p>" }.joined()),
            // 片方だけのときの光の幅を見せるため、お気に入りだけをした投稿にする。
            status("wide", minutes: 7, account: friend, content: PreviewPhoto.credit([.wide]), media: [wideImage], favourited: true),
            status("poll", minutes: 5, account: longNamed, content: "<p>アイコンの形はどちらが好きですか？</p>", poll: poll),
            status("filtered", minutes: 2, account: scia, content: "<p>自分のフィルターに一致した自分の投稿です。</p>", filtered: [ownFilter]),
            // 名前の行の部品を1件で見せる投稿。入りきらない名前、公開範囲の記号、編集済みの「*」を出し、名前と画像のあいだを見せるため本文を付けないので、写真のクレジットは書かない。
            // 画像は、見本の枠に収まるよう横長にする。
            status("name", minutes: 1.5, account: longNamed, content: "", media: [wideImage], visibility: .unlisted, edited: true),
            // 段落のあいだ、引用の字下げ、本文の絵文字を見せる投稿。
            status("paragraphs", minutes: 1.2, account: friend, content: "<p>段落の1つ目です🎉:scia:</p><blockquote><p>引用した文です。</p></blockquote><p>段落の2つ目です。</p>", emojis: emojis),
            plainBoost,
            // 行の余白と区切り線を見せる、部品の少ない投稿の次に並べる1行の投稿。
            status("next", minutes: 0.5, account: scia, content: "<p>次の投稿です。</p>"),
            // 返信をつなぐ線を見せる、本文だけの2件。一覧と同じく、すぐ上の投稿への返信は線でつなぎ、返信のラベルを出さない。
            status("parent", minutes: 1.1, account: scia, content: "<p>返信でつながった投稿の最初の投稿です。</p>"),
            status("child", minutes: 1, account: friend, content: "<p>返信です。</p>", replyingTo: scia, inReplyTo: "preview-parent"),
        ]
    }
}
