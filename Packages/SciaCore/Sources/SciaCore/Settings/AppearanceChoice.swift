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
    case showsQuote
    case showsEmbedAvatar
    case showsPoll
    case showsReactions
    case showsReactionGlow

    /// `group`の分類の画面に並べる項目。上から並べる順。選んで決める項目のない分類では空。
    /// 白より明るく描けない画面のUIは、`drawsReactionGlowInHDR`を除く。
    public static func choices(inGroup group: AppearanceGroup.ID) -> [AppearanceChoice] {
        switch group {
        // 部品を表示するかのスイッチは、その分類の先頭に置く。
        case "row": [.showsSeparators]
        case "context": [.contextNameStyle, .showsContextSymbol, .showsBoosterAvatar, .showsReplyLabel]
        case "avatar": [.showsAvatar, .avatarShape, .showsAvatarBorder, .animatesAvatars, .wrapsBelowAvatar, .showsReplyLines]
        case "name": [.showsNameRow, .nameStyle, .stacksNameParts, .timeStyle, .boldsName, .showsTime, .showsVisibilitySymbol, .showsEditedMark]
        case "body": [.showsBody, .showsReadMore, .showsFilterNote, .glyphLanguage, .emojiStyle, .animatesCustomEmojis]
        case "spoiler": [.showsSpoiler]
        case "media": [.showsMedia, .mediaArrangement, .embedMediaArrangement, .tiltsStackedPhotos, .showsMediaBadges]
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
        case .showsQuote: "引用を表示"
        case .showsEmbedAvatar: "アイコンを表示"
        case .showsPoll: "投票を表示"
        case .showsReactions: "絵文字のリアクションを表示"
        case .showsReactionGlow: "光を表示"
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
        // 引用とXの投稿だけを右に出すときは、囲みの中の写真を示す。
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
        case .showsQuote: .firstOf([.part(.xPost), .part(.quoteSlot)])
        case .showsEmbedAvatar: .part(.xPostAvatar)
        case .showsPoll: .firstOf([.part(.poll), .part(.pollSlot)])
        case .showsReactions: .firstOf([.part(.reactions), .part(.reactionsSlot)])
        case .showsReactionGlow: .part(.reactionGlow)
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
    /// 今選んでいる選択肢の番号。
    public let selectedIndex: (AppSettings) -> Int
    /// `titles`の番号の選択肢を選ぶ。
    public let select: (Int, AppSettings) -> Void

    init<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ options: [(value: Value, title: String)]) {
        titles = options.map(\.title)
        selectedIndex = { settings in options.firstIndex { $0.value == settings[keyPath: keyPath] } ?? 0 }
        select = { index, settings in
            guard options.indices.contains(index) else { return }
            settings[keyPath: keyPath] = options[index].value
        }
    }
}

extension AppearanceChoice {
    @MainActor
    public var control: AppearanceChoiceControl {
        switch self {
        case .showsSeparators: .toggle(\.appearance.showsSeparators)
        case .contextNameStyle: .options(AppearanceChoiceOptions(\.appearance.contextNameStyle, Self.nameStyles))
        case .showsContextSymbol: .toggle(\.appearance.showsContextSymbol)
        case .showsBoosterAvatar: .toggle(\.appearance.showsBoosterAvatar)
        case .showsReplyLabel: .toggle(\.appearance.showsReplyLabel)
        case .avatarShape: .options(AppearanceChoiceOptions(\.appearance.avatarShape, [(.circle, "円"), (.roundedSquare, "角丸の四角")]))
        case .showsAvatarBorder: .toggle(\.appearance.showsAvatarBorder)
        // 選ぶまではサーバーの設定に従うので、今の値は`AppSettings`から読む。
        case .animatesAvatars: .toggle(\.animatesAvatars)
        case .wrapsBelowAvatar: .toggle(\.appearance.wrapsBelowAvatar)
        case .showsReplyLines: .toggle(\.appearance.showsReplyLines)
        case .nameStyle: .options(AppearanceChoiceOptions(\.appearance.statusNameStyle, Self.nameStyles))
        case .stacksNameParts: .toggle(\.appearance.stacksNameParts)
        case .timeStyle: .options(AppearanceChoiceOptions(\.appearance.statusTimeStyle, [(.relative, "相対時刻"), (.absolute, "日時")]))
        case .boldsName: .toggle(\.appearance.boldsName)
        case .showsTime: .toggle(\.appearance.showsTime)
        case .showsVisibilitySymbol: .toggle(\.appearance.showsVisibilitySymbol)
        case .showsEditedMark: .toggle(\.appearance.showsEditedMark)
        case .glyphLanguage:
            .options(AppearanceChoiceOptions(\.appearance.glyphLanguage, [
                (.automatic, "自動"), (.japanese, "日本語"), (.simplifiedChinese, "簡体字中国語"), (.traditionalChinese, "繁体字中国語"), (.korean, "韓国語"),
            ]))
        case .emojiStyle: .options(AppearanceChoiceOptions(\.appearance.emojiStyle, [(.system, "Apple"), (.twemoji, "Twemoji")]))
        case .animatesCustomEmojis: .toggle(\.animatesCustomEmojis)
        case .mediaArrangement: .options(AppearanceChoiceOptions(\.appearance.mediaArrangement, [(.belowBody, "本文の下に大きく"), (.besideBody, "本文の右に小さく")]))
        case .embedMediaArrangement:
            .options(AppearanceChoiceOptions(\.appearance.embedMediaArrangement, [(.sameAsPost, "投稿と同じ"), (.besideBody, "本文の右に小さく"), (.belowBody, "本文の下に大きく")]))
        case .tiltsStackedPhotos: .toggle(\.appearance.tiltsStackedPhotos)
        case .showsMediaBadges: .toggle(\.appearance.showsMediaBadges)
        case .showsLinkCard: .toggle(\.appearance.showsLinkCard)
        case .boldsLinkCardTitle: .toggle(\.appearance.boldsLinkCardTitle)
        case .showsLinkCardImage: .toggle(\.appearance.showsLinkCardImage)
        case .linkCardThumbnailSide: .options(AppearanceChoiceOptions(\.appearance.linkCardThumbnailSide, [(.left, "左"), (.right, "右")]))
        case .showsLinkCardSite: .toggle(\.appearance.showsLinkCardSite)
        case .showsActionBar: .toggle(\.appearance.showsActionBar)
        case .showsActionBarCounts: .toggle(\.appearance.showsActionBarCounts)
        case .drawsReactionGlowInHDR: .toggle(\.appearance.drawsReactionGlowInHDR)
        case .reactionGlowIcons:
            .options(AppearanceChoiceOptions(\.appearance.reactionGlowIcons, [(.none, "表示しない"), (.atBottom, "下の端に1つずつ"), (.scattered, "散らす")]))
        case .reactionGlowFillsWidthWhenAlone: .toggle(\.appearance.reactionGlowFillsWidthWhenAlone)
        case .reactionGlowLightFavouriteColor: .options(AppearanceChoiceOptions(\.appearance.reactionGlowLightFavouriteColor, [(.orange, "橙"), (.yellow, "黄色")]))
        case .showsAvatar: .toggle(\.appearance.showsAvatar)
        case .showsNameRow: .toggle(\.appearance.showsNameRow)
        case .showsBody: .toggle(\.appearance.showsBody)
        case .showsReadMore: .toggle(\.appearance.showsReadMore)
        case .showsFilterNote: .toggle(\.appearance.showsFilterNote)
        case .showsSpoiler: .toggle(\.appearance.showsSpoiler)
        case .showsMedia: .toggle(\.appearance.showsMedia)
        case .showsQuote: .toggle(\.appearance.showsQuote)
        case .showsEmbedAvatar: .toggle(\.appearance.showsEmbedAvatar)
        case .showsPoll: .toggle(\.appearance.showsPoll)
        case .showsReactions: .toggle(\.appearance.showsReactions)
        case .showsReactionGlow: .toggle(\.appearance.showsReactionGlow)
        }
    }

    @MainActor private static let nameStyles: [(value: StatusNameStyle, title: String)] = [
        (.nameAndAcct, "名前、ハンドル"),
        (.nameOnly, "名前"),
        (.acctOnly, "ハンドル"),
        (.acctAndName, "ハンドル、名前"),
        (.none, "表示しない"),
    ]
}

extension AppearanceCatalog {
    /// 今の選択で、数値の項目が見た目に効くか。光のアイコンを出さないときの、アイコンの大きさと濃さは効かない。効かない項目は、変えられなくする。
    public static func isUsed(_ value: AppearanceValue, in appearance: AppearanceChoices) -> Bool {
        !(appearance.reactionGlowIcons == .none && [reactionGlowIconSize, reactionGlowIconOpacity].contains(value))
    }

    /// 「投稿の見た目」の、分類を並べる画面の文言。
    public static let resetAllTitle = "すべてデフォルトに戻す"
    public static let resetAllConfirmation = "投稿の見た目をすべてデフォルトに戻しますか？"
    public static let resetTitle = "デフォルトに戻す"
}

extension NotificationAppearanceCatalog {
    public static let resetAllConfirmation = "通知の見た目をすべてデフォルトに戻しますか？"
}
