/// 「投稿の見た目」の、数値ではなく選んで決める項目。どの分類の画面に、どの順で、どんな名前で並べるかと、見本のどこを示すかを持つ。
/// 数値の項目は`AppearanceCatalog.groups`にあり、分類の画面では、選んで決める項目を数値の項目より上に並べる。
public enum AppearanceChoice: Hashable, CaseIterable, Sendable {
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
    case showsActionBar
    case showsActionBarCounts
    case showsAvatar
    case showsNameRow
    case showsBody
    case showsReadMore
    case showsFilterNote
    case showsSpoiler
    case showsMedia
    case mediaDisplay
    case showsQuote
    case showsEmbedAvatar
    case showsPoll
    case showsReactions
    case showsReactionGlow
    case showsCustomEmojis
    case showsNameCustomEmojis

    /// `group`の分類の画面に並べる項目。上から並べる順。選んで決める項目のない分類では空。
    /// 白より明るく描けない画面のUIは、`drawsReactionGlowInHDR`を除く。
    public static func choices(inGroup group: AppearanceGroup.ID) -> [AppearanceChoice] {
        switch group {
        // 部品を表示するかのスイッチは、その分類の先頭に置く。
        case "row": [.showsSeparators]
        case "context": [.contextNameStyle, .showsContextSymbol, .showsBoosterAvatar, .showsReplyLabel]
        case "avatar": [.showsAvatar, .avatarShape, .showsAvatarBorder, .animatesAvatars, .wrapsBelowAvatar, .showsReplyLines]
        case "name": [.showsNameRow, .nameStyle, .stacksNameParts, .timeStyle, .showsNameCustomEmojis, .boldsName, .showsTime, .showsVisibilitySymbol, .showsEditedMark]
        case "body": [.showsBody, .showsReadMore, .showsFilterNote, .glyphLanguage, .emojiStyle, .showsCustomEmojis, .animatesCustomEmojis]
        case "spoiler": [.showsSpoiler]
        case "media": [.showsMedia, .mediaDisplay, .mediaArrangement, .embedMediaArrangement, .tiltsStackedPhotos, .showsMediaBadges]
        case "linkCard": [.showsLinkCard, .boldsLinkCardTitle, .showsLinkCardImage, .linkCardThumbnailSide, .showsLinkCardSite]
        case AppearanceCatalog.xPostGroupID: [.showsQuote, .showsEmbedAvatar]
        case "poll": [.showsPoll]
        case "reactions": [.showsReactions]
        case AppearanceCatalog.actionBarGroupID: [.showsActionBar, .showsActionBarCounts]
        // HDRのメディアの明るさの設定はメディアに対するものなので、光はそれに従わせず、ここで別に選ぶ。
        case "reactionGlow": [.showsReactionGlow, .drawsReactionGlowInHDR, .reactionGlowIcons, .reactionGlowFillsWidthWhenAlone, .reactionGlowLightFavouriteColor]
        default: []
        }
    }

    public var title: String {
        switch self {
        case .showsSeparators: "投稿のあいだに区切り線を引く"
        case .contextNameStyle: "ブーストした人の表記"
        case .showsContextSymbol: "ブーストや返信の記号を表示"
        case .showsBoosterAvatar: "ブーストした人のアイコンを表示"
        case .showsReplyLabel: "返信のラベルを表示"
        case .avatarShape: "形"
        case .showsAvatarBorder: "縁取りを表示"
        case .animatesAvatars: "アニメーションを再生する"
        case .wrapsBelowAvatar: "アイコンの下を空けない"
        case .showsReplyLines: "返信をつなぐ線を表示"
        case .nameStyle: "名前の表記"
        case .stacksNameParts: "名前とハンドルを2段に分ける"
        case .timeStyle: "時刻の表記"
        case .boldsName: "名前を太字にする"
        case .showsTime: "時刻を表示"
        case .showsVisibilitySymbol: "公開範囲の記号を表示"
        case .showsEditedMark: "編集済みの“*”を表示"
        case .glyphLanguage: "漢字の字形"
        case .emojiStyle: "絵文字"
        case .animatesCustomEmojis: "カスタム絵文字のアニメーションを再生する"
        case .mediaArrangement: "並べ方"
        case .embedMediaArrangement: "引用"
        case .tiltsStackedPhotos: "写真を傾ける"
        case .showsMediaBadges: "ALTやGIFのバッジを表示"
        case .showsLinkCard: "リンクカードを表示"
        case .boldsLinkCardTitle: "タイトルを太字にする"
        case .showsLinkCardImage: "画像を表示"
        case .linkCardThumbnailSide: "画像の位置"
        case .showsLinkCardSite: "サイト名を表示"
        case .showsActionBar: "アクションバーを常に表示"
        case .showsActionBarCounts: "件数を表示"
        case .drawsReactionGlowInHDR: "HDRに対応した画面では白より明るく光らせる"
        case .reactionGlowIcons: "アイコン"
        case .reactionGlowFillsWidthWhenAlone: "片方だけのときは全幅を光らせる"
        case .reactionGlowLightFavouriteColor: "ライトモードのお気に入りの色"
        case .showsAvatar: "アイコンを表示"
        case .showsNameRow: "名前の行を表示"
        case .showsBody: "本文を表示"
        case .showsReadMore: "“続きを読む”を表示"
        case .showsFilterNote: "フィルターの注記を表示"
        case .showsSpoiler: "注意書きを表示"
        case .showsMedia: "メディアを表示"
        case .mediaDisplay: "表示"
        case .showsQuote: "引用を表示"
        case .showsEmbedAvatar: "アイコンを表示"
        case .showsPoll: "投票を表示"
        case .showsReactions: "絵文字のリアクションを表示"
        case .showsReactionGlow: "光を表示"
        case .showsCustomEmojis, .showsNameCustomEmojis: "カスタム絵文字を表示"
        }
    }

    /// 今の選択で、この項目を変えられるか。ほかの選択のために見た目に効かない項目は、変えられなくする。
    public func isEnabled(in appearance: AppearanceChoices) -> Bool {
        switch self {
        // アイコンの下を空けないときは、線の通る場所に本文などが入るので、線を出さない。
        case .showsReplyLines: !appearance.wrapsBelowAvatar
        case .stacksNameParts: appearance.statusNameStyle.parts.count >= 2
        case .tiltsStackedPhotos: appearance.stacksMediaBesideBody
        case .linkCardThumbnailSide: appearance.showsLinkCardImage
        default: true
        }
    }

    /// 見本の中で、この項目が効く場所。
    public var highlight: AppearanceHighlight {
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
        // 引用とXの投稿だけを右に出すときは、カードの中の写真を示す。
        case .tiltsStackedPhotos: .firstOf([.part(.besideMedia), .part(.xPostBesideMedia), .part(.media)])
        case .embedMediaArrangement: .firstOf([.part(.xPostBesideMedia), .part(.xPostMedia)])
        case .drawsReactionGlowInHDR, .reactionGlowLightFavouriteColor: .part(.reactionGlow)
        case .reactionGlowFillsWidthWhenAlone: .firstOf([.part(.reactionGlowAlone), .part(.reactionGlow)])
        case .reactionGlowIcons: .firstOf([.part(.reactionGlowIcons), .part(.reactionGlow)])
        case .showsActionBar: .part(.actionBar)
        case .showsActionBarCounts: .firstOf([.part(.actionBarCounts), .part(.actionBar)])
        case .showsAvatar: .part(.avatar)
        case .showsNameRow: .part(.nameRowSlot)
        case .showsBody: .firstOf([.part(.bodyText), .part(.bodySlot)])
        case .showsReadMore: .firstOf([.part(.readMore), .part(.truncatedBody)])
        case .showsFilterNote: .firstOf([.part(.filterNote), .part(.filterNoteSlot)])
        case .showsSpoiler: .firstOf([.part(.spoiler), .part(.spoilerSlot)])
        case .showsMedia: .firstOf([.part(.media), .part(.besideMedia), .part(.mediaSlot)])
        case .mediaDisplay: .firstOf([.part(.media), .part(.besideMedia)])
        case .showsQuote: .firstOf([.part(.xPost), .part(.quoteSlot)])
        case .showsEmbedAvatar: .part(.xPostAvatar)
        case .showsPoll: .firstOf([.part(.poll), .part(.pollSlot)])
        case .showsReactions: .firstOf([.part(.reactions), .part(.reactionsSlot)])
        case .showsReactionGlow: .part(.reactionGlow)
        case .showsCustomEmojis: .firstOf([.part(.customEmojis), .part(.bodyText)])
        case .showsNameCustomEmojis: .firstOf([.part(.nameCustomEmojis), .part(.nameRow)])
        }
    }

    /// ライトの外観でだけ効く項目か。見本をライトで描いて見せる。
    public var appliesOnlyInLightAppearance: Bool {
        self == .reactionGlowLightFavouriteColor
    }
}

/// 選んで決める項目の部品。スイッチか、名前の付いた選択肢から1つを選ぶ。
@MainActor
public enum AppearanceChoiceControl {
    /// スイッチ。設定の場所を持つ。
    case toggle(ReferenceWritableKeyPath<AppSettings, Bool>)
    case options(AppearanceChoiceOptions)
}

/// 名前の付いた選択肢。値の型は項目ごとに違うので、並びの番号で読み書きする。
@MainActor
public struct AppearanceChoiceOptions {
    /// 選択肢の名前。並べる順。
    public let titles: [String]
    /// 選択肢の名前の下に添える文。`titles`と同じ順で、添えない選択肢はnil。「アカウント設定に従う」に、今のアカウントの値を添える。
    public let subtitles: (AppSettings) -> [String?]
    /// 今選んでいる選択肢の番号。
    public let selectedIndex: (AppSettings) -> Int
    /// `titles`の番号の選択肢を選ぶ。
    public let select: (Int, AppSettings) -> Void

    private init(titles: [String], subtitles: @escaping (AppSettings) -> [String?], selectedIndex: @escaping (AppSettings) -> Int, select: @escaping (Int, AppSettings) -> Void) {
        self.titles = titles
        self.subtitles = subtitles
        self.selectedIndex = selectedIndex
        self.select = select
    }

    /// 選んだあとに、選んだ値を`field`の選択肢としてプリセットに書く。
    func pinning(_ field: String) -> Self {
        let select = select
        return Self(titles: titles, subtitles: subtitles, selectedIndex: selectedIndex) { index, settings in
            select(index, settings)
            settings.pinAppearanceChoice(field)
        }
    }

    init<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ options: [(value: Value, title: String)], subtitle: @escaping (Value, AppSettings) -> String?) {
        titles = options.map(\.title)
        subtitles = { settings in options.map { subtitle($0.value, settings) } }
        selectedIndex = { settings in options.firstIndex { $0.value == settings[keyPath: keyPath] } ?? 0 }
        select = { index, settings in
            guard options.indices.contains(index) else { return }
            settings[keyPath: keyPath] = options[index].value
        }
    }
}

/// 選んで決める項目の、部品と保存先。保存先は`AppearanceChoices`のプロパティで、既定の値はその初期値。
@MainActor
struct AppearanceChoiceDefinition {
    let control: AppearanceChoiceControl
    let isModified: (AppearanceChoices) -> Bool
    let reset: (inout AppearanceChoices) -> Void

    private init<Stored: Equatable>(control: AppearanceChoiceControl, stored: WritableKeyPath<AppearanceChoices, Stored>) {
        self.control = control
        isModified = { $0[keyPath: stored] != AppearanceChoices()[keyPath: stored] }
        reset = { $0[keyPath: stored] = AppearanceChoices()[keyPath: stored] }
    }

    static func toggle(_ stored: WritableKeyPath<AppearanceChoices, Bool>) -> Self {
        Self(control: .toggle(settingsKeyPath(stored)), stored: stored)
    }

    /// - Parameter subtitle: 選択肢の名前の下に添える文。添えなければnilを返す。
    static func options<Value: Equatable>(
        _ stored: WritableKeyPath<AppearanceChoices, Value>,
        _ options: [(value: Value, title: String)],
        subtitle: @escaping @MainActor (Value, AppSettings) -> String? = { _, _ in nil }
    ) -> Self {
        Self(control: .options(AppearanceChoiceOptions(settingsKeyPath(stored), options, subtitle: subtitle)), stored: stored)
    }

    private static func settingsKeyPath<Value>(_ stored: WritableKeyPath<AppearanceChoices, Value>) -> ReferenceWritableKeyPath<AppSettings, Value> {
        // ファイルの名前ではなく、キーパスをつなげている。
        // swiftlint:disable:next unsafe_file_name
        (\AppSettings.appearance).appending(path: stored)
    }
}

extension AppearanceChoice {
    @MainActor
    /// メニューで選んだ選択肢は、読んでいるプリセットの値として持つ。親から受け継いだ値と同じでも持つので、あとで親を変えても選んだ値のまま残る（docs/preset.md）。
    public var control: AppearanceChoiceControl {
        switch definition.control {
        case .toggle(let keyPath): .toggle(keyPath)
        case .options(let options): .options(options.pinning(field))
        }
    }

    /// 既定の値から変わっているか。
    @MainActor
    public func isModified(in appearance: AppearanceChoices) -> Bool {
        definition.isModified(appearance)
    }

    /// 既定の値へ戻す。
    @MainActor
    public func reset(in appearance: inout AppearanceChoices) {
        definition.reset(&appearance)
    }

    @MainActor
    private var definition: AppearanceChoiceDefinition {
        switch self {
        case .showsSeparators: .toggle(\.showsSeparators)
        case .contextNameStyle: .options(\.contextNameStyle, Self.nameStyles)
        case .showsContextSymbol: .toggle(\.showsContextSymbol)
        case .showsBoosterAvatar: .toggle(\.showsBoosterAvatar)
        case .showsReplyLabel: .toggle(\.showsReplyLabel)
        case .avatarShape: .options(\.avatarShape, [(.circle, "円"), (.roundedSquare, "四角")])
        case .showsAvatarBorder: .toggle(\.showsAvatarBorder)
        // 選ぶまではサーバーの設定に従うので、今の値は`AppSettings`から読む。
        case .animatesAvatars: .options(\.animatesAvatars, Self.animationChoices, subtitle: Self.serverAnimationSubtitle)
        case .wrapsBelowAvatar: .toggle(\.wrapsBelowAvatar)
        case .showsReplyLines: .toggle(\.showsReplyLines)
        case .nameStyle: .options(\.statusNameStyle, Self.nameStyles)
        case .stacksNameParts: .toggle(\.stacksNameParts)
        case .timeStyle: .options(\.statusTimeStyle, [(.relative, "相対時刻"), (.absolute, "日時")])
        case .boldsName: .toggle(\.boldsName)
        case .showsTime: .toggle(\.showsTime)
        case .showsVisibilitySymbol: .toggle(\.showsVisibilitySymbol)
        case .showsEditedMark: .toggle(\.showsEditedMark)
        case .glyphLanguage:
            .options(\.glyphLanguage, [
                (.automatic, "自動"), (.japanese, "日本語"), (.simplifiedChinese, "簡体字中国語"), (.traditionalChinese, "繁体字中国語"), (.korean, "韓国語"),
            ])
        case .emojiStyle: .options(\.emojiStyle, [(.system, "Apple"), (.twemoji, "Twemoji")])
        case .animatesCustomEmojis: .options(\.animatesCustomEmojis, Self.animationChoices, subtitle: Self.serverAnimationSubtitle)
        // 選ぶまではサーバーの設定に従うので、今の値は`AppSettings`から読む。
        case .mediaDisplay:
            .options(\.mediaDisplay, [(nil, Self.followsAccountTitle)] + MediaDisplay.allCases.map { ($0, $0.title) }) { value, settings in
                value == nil ? settings.serverMediaDisplay.title : nil
            }
        case .mediaArrangement: .options(\.mediaArrangement, [(.belowBody, "本文の下に大きく"), (.besideBody, "本文の右に小さく")])
        case .embedMediaArrangement:
            .options(\.embedMediaArrangement, [(.sameAsPost, "投稿と同じ"), (.besideBody, "本文の右に小さく"), (.belowBody, "本文の下に大きく")])
        case .tiltsStackedPhotos: .toggle(\.tiltsStackedPhotos)
        case .showsMediaBadges: .toggle(\.showsMediaBadges)
        case .showsLinkCard: .toggle(\.showsLinkCard)
        case .boldsLinkCardTitle: .toggle(\.boldsLinkCardTitle)
        case .showsLinkCardImage: .toggle(\.showsLinkCardImage)
        case .linkCardThumbnailSide: .options(\.linkCardThumbnailSide, [(.left, "左"), (.right, "右")])
        case .showsLinkCardSite: .toggle(\.showsLinkCardSite)
        case .showsActionBar: .toggle(\.showsActionBar)
        case .showsActionBarCounts: .toggle(\.showsActionBarCounts)
        case .drawsReactionGlowInHDR: .toggle(\.drawsReactionGlowInHDR)
        case .reactionGlowIcons:
            .options(\.reactionGlowIcons, [(.none, "表示しない"), (.atBottom, "下の端に1つずつ"), (.scattered, "散らす")])
        case .reactionGlowFillsWidthWhenAlone: .toggle(\.reactionGlowFillsWidthWhenAlone)
        case .reactionGlowLightFavouriteColor: .options(\.reactionGlowLightFavouriteColor, [(.orange, "橙"), (.yellow, "黄色")])
        case .showsAvatar: .toggle(\.showsAvatar)
        case .showsNameRow: .toggle(\.showsNameRow)
        case .showsBody: .toggle(\.showsBody)
        case .showsReadMore: .toggle(\.showsReadMore)
        case .showsFilterNote: .toggle(\.showsFilterNote)
        case .showsSpoiler: .toggle(\.showsSpoiler)
        case .showsMedia: .toggle(\.showsMedia)
        case .showsQuote: .toggle(\.showsQuote)
        case .showsEmbedAvatar: .toggle(\.showsEmbedAvatar)
        case .showsPoll: .toggle(\.showsPoll)
        case .showsReactions: .toggle(\.showsReactions)
        case .showsReactionGlow: .toggle(\.showsReactionGlow)
        case .showsCustomEmojis: .toggle(\.showsCustomEmojis)
        case .showsNameCustomEmojis: .toggle(\.showsNameCustomEmojis)
        }
    }

    /// アニメーションを再生するか。「アカウント設定に従う」はサーバーのアカウントの設定に従い、親のプリセットがオンやオフを持っていても選べる（docs/preset.md）。
    /// サーバーのアカウント設定に従う選択肢の名前。
    static let followsAccountTitle = "アカウント設定に従う"

    /// 「アカウント設定に従う」に添える、今のアカウントの値。
    @MainActor private static func serverAnimationSubtitle(_ value: Bool?, _ settings: AppSettings) -> String? {
        guard value == nil else { return nil }
        return settings.serverAutoplaysAnimations ? "オン" : "オフ"
    }

    @MainActor private static let animationChoices: [(value: Bool?, title: String)] = [
        (nil, followsAccountTitle),
        (true, "オン"),
        (false, "オフ"),
    ]

    @MainActor private static let nameStyles: [(value: StatusNameStyle, title: String)] = [
        (.nameAndAcct, "名前、ハンドル"),
        (.nameOnly, "名前"),
        (.acctOnly, "ハンドル"),
        (.acctAndName, "ハンドル、名前"),
        (.none, "表示しない"),
    ]
}

extension AppearanceCatalog {
    /// 今の選択で、数値の項目が見た目に効くか。光のアイコンを出さないときの、アイコンの大きさと不透明度は効かない。効かない項目は、変えられなくする。
    public static func isUsed(_ value: AppearanceValue, in appearance: AppearanceChoices) -> Bool {
        !(appearance.reactionGlowIcons == .none && [reactionGlowIconSize, reactionGlowIconOpacity].contains(value))
    }

    /// 「投稿の見た目」の、分類を並べる画面の文言。すべての項目を、親のプリセット（`parentName`）の値に従わせる。
    public static func resetAllTitle(parentName: String) -> String {
        "すべて“\(parentName)”に従う"
    }

    public static func resetAllConfirmation(parentName: String) -> String {
        "投稿の見た目をすべて“\(parentName)”に従わせますか？"
    }

    public static func resetTitle(parentName: String) -> String {
        SettingsTexts.Appearance.followParent(name: parentName)
    }
}

extension NotificationAppearanceCatalog {
    public static func resetAllConfirmation(parentName: String) -> String {
        "通知の見た目をすべて“\(parentName)”に従わせますか？"
    }
}
