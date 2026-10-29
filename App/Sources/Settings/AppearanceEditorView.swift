import SciaCore
import SwiftUI
import UIKit

/// 「投稿の見た目」。上にプレビューを固定し、下に投稿の部品ごとの項目を、投稿の上から下への並びで置く。
/// 項目を触っている間は、プレビューでその場所を示す。プレビューの部品をタップすると、その部品の項目を開く。
struct AppearanceEditorView: View {
    @Bindable var settings: AppSettings
    private let tuning: TuningStore
    @State private var samples: AppearanceSamples
    /// カスタム絵文字の画像が届いたら、プレビューを描き直す。本文は描いた時点の画像で組むため。
    @State private var emojiArrivals = EmojiArrivals(store: AppDependencies.emojiImages)
    /// 最後に触った項目。プレビューでその場所を示す。
    @State private var focused: AppearanceFocus?
    @State private var expandedGroups: Set<AppearanceGroup.ID> = []
    /// プレビューでタップした部品の項目。リストをそこまでスクロールする。項目を触ったときは、押している行を動かさないようスクロールしない。
    @State private var scrollTarget: AppearanceGroup.ID?
    @State private var confirmsReset = false
    @Environment(\.colorScheme) private var colorScheme

    init(settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        self.tuning = tuning
        _samples = State(initialValue: AppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                AppearancePreview(
                    configurations: samples.configurations(colorScheme: previewColorScheme, revision: revision),
                    highlight: focused?.highlight,
                    onSelectPart: select,
                    onTapHighlight: { focused = nil },
                    showsSeparators: settings.showsSeparators,
                    choices: choicesRevision,
                    interfaceStyle: focused?.colorScheme.map { $0 == .dark ? .dark : .light } ?? .unspecified
                )
                .frame(height: geometry.size.height * 0.42)
                Divider()
                ScrollViewReader { proxy in
                    Form {
                        // 開いていない部品は1行に縮むので、1つのセクションに並べて全体を見渡せるようにする。
                        Section {
                            ForEach(groups) { group in
                                DisclosureGroup(isExpanded: expansion(of: group)) {
                                    choices(of: group)
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
                                } label: {
                                    GroupLabel(title: group.title, isModified: group.values.contains(where: settings.isModified))
                                }
                                .id(group.id)
                            }
                        } footer: {
                            Text("プレビューの部品をタップすると、その部品の項目を開きます。項目の名前やプレビューをもう一度タップすると、場所を示すのをやめます。")
                        }
                        Section {
                            Button("すべて既定に戻す", role: .destructive) { confirmsReset = true }
                                .disabled(!settings.isAppearanceModified)
                        } footer: {
                            Text("文字の大きさは、iPhoneの文字サイズが標準のときの大きさです。本文はiPhoneの文字サイズに合わせて伸び縮みし、ほかの文字は本文との差を保ちます。")
                        }
                    }
                    // スイッチは押すとすぐ切り替わるので、切り替えたときにその場所を示す。メニューで選ぶ項目は、メニューを開いたときに示す。
                    .onChange(of: settings.showsBoosterAvatar) { focused = .choice(.showsBoosterAvatar) }
                    .onChange(of: settings.showsContextSymbol) { focused = .choice(.showsContextSymbol) }
                    .onChange(of: settings.boldsName) { focused = .choice(.boldsName) }
                    .onChange(of: settings.showsAvatarBorder) { focused = .choice(.showsAvatarBorder) }
                    .onChange(of: settings.showsMediaBadges) { focused = .choice(.showsMediaBadges) }
                    .onChange(of: settings.tiltsStackedPhotos) { focused = .choice(.tiltsStackedPhotos) }
                    .onChange(of: settings.showsLinkCard) { focused = .choice(.showsLinkCard) }
                    .onChange(of: settings.boldsLinkCardTitle) { focused = .choice(.boldsLinkCardTitle) }
                    .onChange(of: settings.showsSeparators) { focused = .choice(.showsSeparators) }
                    .onChange(of: settings.showsReplyLabel) { focused = .choice(.showsReplyLabel) }
                    .onChange(of: settings.showsReplyLines) { focused = .choice(.showsReplyLines) }
                    .onChange(of: settings.showsTime) { focused = .choice(.showsTime) }
                    .onChange(of: settings.showsVisibilitySymbol) { focused = .choice(.showsVisibilitySymbol) }
                    .onChange(of: settings.showsEditedMark) { focused = .choice(.showsEditedMark) }
                    .onChange(of: settings.showsLinkCardSite) { focused = .choice(.showsLinkCardSite) }
                    .onChange(of: settings.showsLinkCardImage) { focused = .choice(.showsLinkCardImage) }
                    .onChange(of: settings.animatesAvatars) { focused = .choice(.animatesAvatars) }
                    .onChange(of: settings.animatesCustomEmojis) { focused = .choice(.animatesCustomEmojis) }
                    .onChange(of: settings.drawsReactionGlowInHDR) { focused = .choice(.drawsReactionGlowInHDR) }
                    .onChange(of: settings.reactionGlowFillsWidthWhenAlone) { focused = .choice(.reactionGlowFillsWidthWhenAlone) }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                }
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
        .navigationTitle("投稿の見た目")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("投稿の見た目をすべて既定に戻しますか？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("既定に戻す", role: .destructive) {
                settings.resetAppearance()
                focused = nil
            }
        }
    }

    /// 見本を描く外観。外観ごとにしか効かない項目を触っている間は、その外観で描く。端末と違う外観の項目では、値を変えても見た目が変わらないため。
    private var previewColorScheme: ColorScheme {
        focused?.colorScheme ?? colorScheme
    }

    private var groups: [AppearanceGroup] {
        AppearanceCatalog.groups
    }

    /// プレビューを描き直すきっかけ。見本の組み立ては設定を直接読むので、読んだ値が変わったら描き直すよう、ここで読んでおく。
    private var revision: Int {
        var hasher = Hasher()
        hasher.combine(emojiArrivals.count)
        hasher.combine(settings.appearanceValues)
        hasher.combine(choicesRevision)
        return hasher.finalize()
    }

    /// 数値以外の設定。変わったときは、プレビューの部品を動かさずに切り替える。
    private var choicesRevision: Int {
        var hasher = Hasher()
        hasher.combine(settings.statusNameStyle)
        hasher.combine(settings.contextNameStyle)
        hasher.combine(settings.showsVisibilitySymbol)
        hasher.combine(settings.showsEditedMark)
        hasher.combine(settings.showsLinkCardSite)
        hasher.combine(settings.showsBoosterAvatar)
        hasher.combine(settings.showsContextSymbol)
        hasher.combine(settings.boldsName)
        hasher.combine(settings.showsAvatarBorder)
        hasher.combine(settings.showsMediaBadges)
        hasher.combine(settings.showsLinkCard)
        hasher.combine(settings.boldsLinkCardTitle)
        hasher.combine(settings.showsSeparators)
        hasher.combine(settings.showsReplyLabel)
        hasher.combine(settings.showsReplyLines)
        hasher.combine(settings.showsTime)
        hasher.combine(settings.showsLinkCardImage)
        hasher.combine(settings.statusTimeStyle)
        hasher.combine(settings.avatarShape)
        hasher.combine(settings.animatesAvatars)
        hasher.combine(settings.animatesCustomEmojis)
        hasher.combine(settings.linkCardThumbnailSide)
        hasher.combine(settings.mediaArrangement)
        hasher.combine(settings.tiltsStackedPhotos)
        hasher.combine(settings.glyphLanguage)
        hasher.combine(settings.emojiStyle)
        hasher.combine(settings.drawsReactionGlowInHDR)
        hasher.combine(settings.reactionGlowIcons)
        hasher.combine(settings.reactionGlowFillsWidthWhenAlone)
        hasher.combine(settings.reactionGlowLightFavouriteColor)
        return hasher.finalize()
    }

    private func expansion(of group: AppearanceGroup) -> Binding<Bool> {
        Binding {
            expandedGroups.contains(group.id)
        } set: { isExpanded in
            if isExpanded {
                expandedGroups.insert(group.id)
            } else {
                expandedGroups.remove(group.id)
            }
        }
    }

    /// プレビューでタップした部品のうち、項目のある最も小さい部品の項目を開き、その場所を示す。
    /// 部品のない場所や、いま示している項目の部品をタップしたときは、示すのをやめる。示した帯で、確かめたい見た目が隠れることがあるため。
    private func select(_ parts: [AppearancePreviewPart]) {
        guard let item = parts.lazy.compactMap(AppearanceHighlight.item(selectedBy:)).first,
              let group = groups.first(where: { $0.values.contains(item) }),
              focused != .value(item) else {
            focused = nil
            return
        }
        expandedGroups.insert(group.id)
        focused = .value(item)
        scrollTarget = group.id
    }

    /// 項目の名前をタップしたとき、その項目の場所を示す。示していれば、示すのをやめる。
    private func toggleFocus(_ focus: AppearanceFocus) {
        focused = focused == focus ? nil : focus
    }

    /// 数値ではなく選んで決める項目。その部品の項目の先頭に置く。
    @ViewBuilder
    private func choices(of group: AppearanceGroup) -> some View {
        switch group.id {
        case "row":
            TitledToggleRow(title: "投稿のあいだに区切り線を引く", isOn: $settings.showsSeparators) { toggleFocus(.choice(.showsSeparators)) }
        case "context":
            PopUpChoiceRow(title: "ブーストした人の表記", selection: $settings.contextNameStyle, options: Self.nameStyles, onOpen: { focus(.contextNameStyle) }, onTapTitle: { toggleFocus(.choice(.contextNameStyle)) })
            TitledToggleRow(title: "ブーストや返信の記号を出す", isOn: $settings.showsContextSymbol) { toggleFocus(.choice(.showsContextSymbol)) }
            TitledToggleRow(title: "ブーストした人のアイコンを出す", isOn: $settings.showsBoosterAvatar) { toggleFocus(.choice(.showsBoosterAvatar)) }
            TitledToggleRow(title: "返信のラベルを出す", isOn: $settings.showsReplyLabel) { toggleFocus(.choice(.showsReplyLabel)) }
        case "avatar":
            PopUpChoiceRow(title: "形", selection: $settings.avatarShape, options: [(.circle, "円"), (.roundedSquare, "角丸の四角")], onOpen: { focus(.avatarShape) }, onTapTitle: { toggleFocus(.choice(.avatarShape)) })
            TitledToggleRow(title: "縁取りを出す", isOn: $settings.showsAvatarBorder) { toggleFocus(.choice(.showsAvatarBorder)) }
            TitledToggleRow(title: "アニメーションを再生する", isOn: $settings.animatesAvatars) { toggleFocus(.choice(.animatesAvatars)) }
            TitledToggleRow(title: "返信をつなぐ線を出す", isOn: $settings.showsReplyLines) { toggleFocus(.choice(.showsReplyLines)) }
        case "name":
            PopUpChoiceRow(title: "名前の表記", selection: $settings.statusNameStyle, options: Self.nameStyles, onOpen: { focus(.nameStyle) }, onTapTitle: { toggleFocus(.choice(.nameStyle)) })
            PopUpChoiceRow(title: "時刻の表記", selection: $settings.statusTimeStyle, options: [(.relative, "相対時刻"), (.absolute, "日時")], onOpen: { focus(.timeStyle) }, onTapTitle: { toggleFocus(.choice(.timeStyle)) })
            TitledToggleRow(title: "名前を太字にする", isOn: $settings.boldsName) { toggleFocus(.choice(.boldsName)) }
            TitledToggleRow(title: "時刻を出す", isOn: $settings.showsTime) { toggleFocus(.choice(.showsTime)) }
            TitledToggleRow(title: "公開範囲の記号を出す", isOn: $settings.showsVisibilitySymbol) { toggleFocus(.choice(.showsVisibilitySymbol)) }
            TitledToggleRow(title: "編集済みの「*」を出す", isOn: $settings.showsEditedMark) { toggleFocus(.choice(.showsEditedMark)) }
        case "body":
            PopUpChoiceRow(
                title: "漢字の字形",
                selection: $settings.glyphLanguage,
                options: [(.automatic, "自動"), (.japanese, "日本語"), (.simplifiedChinese, "簡体字中国語"), (.traditionalChinese, "繁体字中国語"), (.korean, "韓国語")]
            , onOpen: { focus(.glyphLanguage) }, onTapTitle: { toggleFocus(.choice(.glyphLanguage)) })
            PopUpChoiceRow(title: "絵文字", selection: $settings.emojiStyle, options: [(.system, "Apple"), (.twemoji, "Twemoji")], onOpen: { focus(.emojiStyle) }, onTapTitle: { toggleFocus(.choice(.emojiStyle)) })
            TitledToggleRow(title: "カスタム絵文字のアニメーションを再生する", isOn: $settings.animatesCustomEmojis) { toggleFocus(.choice(.animatesCustomEmojis)) }
        case "media":
            PopUpChoiceRow(title: "並べ方", selection: $settings.mediaArrangement, options: [(.belowBody, "本文の下に大きく"), (.besideBody, "本文の右に小さく")], onOpen: { focus(.mediaArrangement) }, onTapTitle: { toggleFocus(.choice(.mediaArrangement)) })
            TitledToggleRow(title: "写真を傾ける", isOn: $settings.tiltsStackedPhotos) { toggleFocus(.choice(.tiltsStackedPhotos)) }
                .disabled(settings.mediaArrangement != .besideBody)
            TitledToggleRow(title: "ALTやGIFのバッジを出す", isOn: $settings.showsMediaBadges) { toggleFocus(.choice(.showsMediaBadges)) }
        case "linkCard":
            TitledToggleRow(title: "リンクカードを出す", isOn: $settings.showsLinkCard) { toggleFocus(.choice(.showsLinkCard)) }
            TitledToggleRow(title: "タイトルを太字にする", isOn: $settings.boldsLinkCardTitle) { toggleFocus(.choice(.boldsLinkCardTitle)) }
            TitledToggleRow(title: "画像を出す", isOn: $settings.showsLinkCardImage) { toggleFocus(.choice(.showsLinkCardImage)) }
            PopUpChoiceRow(title: "画像の位置", selection: $settings.linkCardThumbnailSide, options: [(.left, "左"), (.right, "右")], onOpen: { focus(.linkCardThumbnailSide) }, onTapTitle: { toggleFocus(.choice(.linkCardThumbnailSide)) })
                .disabled(!settings.showsLinkCardImage)
            TitledToggleRow(title: "サイト名を出す", isOn: $settings.showsLinkCardSite) { toggleFocus(.choice(.showsLinkCardSite)) }
        case "reactionGlow":
            // HDRのメディアの明るさの設定はメディアに対するものなので、光はそれに従わせず、ここで別に選ぶ。
            TitledToggleRow(title: "HDRに対応した画面では白より明るく光らせる", isOn: $settings.drawsReactionGlowInHDR) { toggleFocus(.choice(.drawsReactionGlowInHDR)) }
            PopUpChoiceRow(title: "アイコン", selection: $settings.reactionGlowIcons, options: [(.none, "出さない"), (.atBottom, "下の端に1つずつ"), (.scattered, "散らす")], onOpen: { focus(.reactionGlowIcons) }, onTapTitle: { toggleFocus(.choice(.reactionGlowIcons)) })
            TitledToggleRow(title: "片方だけのときは全幅を光らせる", isOn: $settings.reactionGlowFillsWidthWhenAlone) { toggleFocus(.choice(.reactionGlowFillsWidthWhenAlone)) }
            PopUpChoiceRow(title: "ライトモードのお気に入りの色", selection: $settings.reactionGlowLightFavouriteColor, options: [(.orange, "橙"), (.yellow, "黄色")], onOpen: { focus(.reactionGlowLightFavouriteColor) }, onTapTitle: { toggleFocus(.choice(.reactionGlowLightFavouriteColor)) })
        default:
            EmptyView()
        }
    }

    /// ほかの選択肢のために、見た目に効かない項目。光のアイコンを出さないときの、アイコンの大きさと濃さ。
    private func isUnused(_ item: AppearanceValue) -> Bool {
        settings.reactionGlowIcons == .none && [AppearanceCatalog.reactionGlowIconSize, AppearanceCatalog.reactionGlowIconOpacity].contains(item)
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

/// カスタム絵文字の画像が届いた回数。数が変わると、読んだ画面が描き直す。
@MainActor
@Observable
final class EmojiArrivals {
    private(set) var count = 0

    init(store: EmojiImageStore) {
        store.addListener(owner: self) { [weak self] _ in
            self?.count += 1
        }
    }
}

/// 「投稿の見た目」で、最後に触った項目。
enum AppearanceFocus: Hashable {
    case value(AppearanceValue)
    case choice(AppearanceChoice)

    var highlight: AppearanceHighlight? {
        switch self {
        case .value(let item): AppearanceHighlight(item)
        case .choice(let choice): choice.highlight
        }
    }

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
        case .tiltsStackedPhotos: .firstOf([.part(.besideMedia), .part(.media)])
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
                HStack(spacing: 6) {
                    Text(item.title)
                    if settings.isModified(item) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("変更あり")
                    }
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
        case .lines: return offset == 0 ? "出さない" : nil
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

/// プレビューに並べる見本の投稿。調整できる部品がどれかの投稿に出るように組む。
/// 一覧と同じ組み立て（`TimelineViewController`）を通し、画像は通信しないよう、アプリのアイコンから作ったものを使う。
@MainActor
struct AppearanceSamples {
    private let timeline: TimelineViewController
    private let settings: AppSettings
    private let tuning: TuningStore
    private let now: Date
    private let posts: [(status: Status, connection: ReplyConnection)]
    private let lightPosts: [(status: Status, connection: ReplyConnection)]

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        self.settings = settings
        self.tuning = tuning
        self.now = now
        timeline = TimelineViewController(texts: .home, refresh: {}, tuning: tuning, settings: settings)
        // 自分のフィルターに一致した自分の投稿の注記を見せるため、見本のSciaのアカウントを自分として組む。
        timeline.myAccountID = Self.myAccountID
        timeline.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: Self.myAccountID))
        posts = Self.posts(now: now, cardImage: PreviewImages.cardURL(for: .dark))
        lightPosts = Self.posts(now: now, cardImage: PreviewImages.cardURL(for: .light))
        // 注意書きの開閉と本文のあいだを見せるため、注意書きは開いておく。開いた状態は投稿のIDで持つので、外観ごとの見本で同じIDを1回だけ開く。
        for status in posts.map(\.status) where !status.displayed.spoilerText.isEmpty {
            timeline.toggleSpoiler(of: status)
        }
    }

    /// 引用の囲みを出した投稿は、いつも最後に並べる。Xの投稿の囲みも同じ値で描くが、Xの投稿は既定では出さない試作のため、見本には出さない。
    /// - Parameter revision: 描き直しのきっかけ。中身は使わない。
    func configurations(colorScheme: ColorScheme, revision _: Int) -> [PostContentConfiguration] {
        let cardImage = PreviewImages.cardURL(for: colorScheme == .dark ? .dark : .light)
        let configurations = (colorScheme == .dark ? posts : lightPosts).map { post in
            var configuration = timeline.contentConfiguration(for: post.status, base: .cell())
            configuration.replyConnection = post.connection
            return configuration
        }
        return configurations + [quoteConfiguration(image: cardImage)]
    }

    /// 投稿を引用した投稿。引用元には、囲みの中の部品が出るよう、本文と画像を付ける。
    private func quoteConfiguration(image: URL?) -> PostContentConfiguration {
        let avatar = PreviewImages.avatarURL()
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let scia = Account(id: Self.myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let attachment = MediaAttachment(
            id: "preview-quote-image",
            type: .image,
            url: image,
            previewUrl: image,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
        let quoted = Status(
            id: "preview-quoted",
            createdAt: now.addingTimeInterval(-3_600),
            account: scia,
            content: "<p>引用された投稿の本文です。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: [attachment]
        )
        let status = Status(
            id: "preview-quote",
            createdAt: now.addingTimeInterval(-60),
            account: friend,
            content: "<p>投稿を引用した投稿です。</p>",
            spoilerText: "",
            url: nil,
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
        return timeline.contentConfiguration(for: status, base: .cell())
    }

    private static let myAccountID = "preview-scia"

    private static func posts(now: Date, cardImage: URL?) -> [(status: Status, connection: ReplyConnection)] {
        let avatar = PreviewImages.avatarURL()
        // アニメーションを再生する設定の違いを見せるため、アイコンと絵文字には色相の回るアニメーション版を付ける。
        let animated = PreviewImages.animatedAvatarURL() ?? avatar
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: animated, avatarStatic: avatar)
        // カスタム絵文字の大きさを見せるため、アプリのアイコンを絵文字にする。
        let emojis = avatar.map { [CustomEmoji(shortcode: "scia", url: animated ?? $0, staticUrl: $0)] } ?? []
        // 名前の絵文字とカスタム絵文字の大きさを見せるため、名前にも絵文字と本文と同じカスタム絵文字を付ける。
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち🌱:scia:", avatar: animated, avatarStatic: avatar, emojis: emojis)
        // 入りきらない名前の行末のぼかしを見せるため、名前の長いアカウントも用意する。
        let longNamed = Account(id: "preview-long", username: "long", acct: "long@example.com", displayName: "とても長い名前のアカウントで、名前の行に入りきりません", avatar: animated, avatarStatic: avatar)
        let image = MediaAttachment(
            id: "preview-image",
            type: .image,
            url: cardImage,
            previewUrl: cardImage,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
        // 縦長と横長の比率の上限を見せるため、縦長の画像と横長の画像を1枚ずつ出す投稿を用意する。
        let tallImage = MediaAttachment(
            id: "preview-tall-image",
            type: .image,
            url: cardImage,
            previewUrl: cardImage,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 600, height: 1_200))
        )
        let wideImage = MediaAttachment(
            id: "preview-wide-image",
            type: .image,
            url: cardImage,
            previewUrl: cardImage,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 2_400, height: 600))
        )
        // 代替テキストのバッジを見せるため、1枚には代替テキストを付ける。
        let describedImage = MediaAttachment(
            id: "preview-described-image",
            type: .image,
            url: cardImage,
            previewUrl: cardImage,
            description: "アプリのアイコン",
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
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
        func status(_ id: String, minutes: Double, account: Account, content: String, spoiler: String = "", media: [MediaAttachment] = [], poll: Poll? = nil, card: PreviewCard? = nil, replyingTo: Account? = nil, visibility: Status.Visibility = .public, edited: Bool = false, emojis: [CustomEmoji] = [], filtered: [FilterResult] = [], favourited: Bool = false, reblogged: Bool = false) -> Status {
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
                inReplyToId: replyingTo.map { _ in "preview-thread" },
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
        let boosted = status("boosted", minutes: 30, account: friend, content: #"<p>段落の1つ目です。設定を変えると、タイムラインの投稿がこのように表示されます🎉:scia:</p><p>段落の2つ目です。<a href="https://github.com/eai04191/scia">github.com/eai04191/scia</a></p>"#, card: card, emojis: emojis, favourited: true, reblogged: true)
        let boost = Status(id: "preview-boost", createdAt: now.addingTimeInterval(-180), account: scia, content: "", spoilerText: "", url: nil, reblog: boosted)
        let poll = Poll(
            id: "preview-poll",
            expiresAt: now.addingTimeInterval(86_400),
            expired: false,
            multiple: false,
            votesCount: 12,
            options: [Poll.Option(title: "円", votesCount: nil), Poll.Option(title: "角丸の四角", votesCount: nil)]
        )
        return [
            (boost, ReplyConnection()),
            // 注意書きのある投稿の画像はぼかされ、サムネイル同士のすき間が見えないため、画像は注意書きのない投稿に付ける。
            (status("thread", minutes: 20, account: scia, content: "<p>返信でつながった投稿の、最初の投稿です。</p><blockquote><p>引用した文です。</p></blockquote>", media: [describedImage, image]), ReplyConnection(below: true)),
            // 公開範囲の記号と編集済みの「*」を見せるため、未収載で編集した投稿にする。
            (status("reply", minutes: 12, account: friend, content: "<p>注意書きの下の本文です。</p>", spoiler: "注意書き", replyingTo: scia, visibility: .unlisted, edited: true), ReplyConnection(above: true)),
            (status("media", minutes: 8, account: scia, content: "", media: [tallImage]), ReplyConnection()),
            // 絵文字だけの本文を見せるため、先頭にメンションの付いた、絵文字だけの返信を用意する。メンションは大きくしない。
            (status("emoji-only", minutes: 7.5, account: friend, content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> 👍:scia:🎉</p>"#, replyingTo: scia, emojis: emojis), ReplyConnection()),
            // 片方だけのときの光の幅を見せるため、お気に入りだけをした投稿にする。
            (status("wide", minutes: 7, account: friend, content: "<p>横長の画像を1枚付けた投稿です。</p>", media: [wideImage], favourited: true), ReplyConnection()),
            (status("poll", minutes: 5, account: longNamed, content: "<p>アイコンの形はどちらが好きですか？</p>", poll: poll), ReplyConnection()),
            (status("filtered", minutes: 2, account: scia, content: "<p>自分のフィルターに一致した、自分の投稿です。</p>", filtered: [ownFilter]), ReplyConnection()),
        ]
    }
}
