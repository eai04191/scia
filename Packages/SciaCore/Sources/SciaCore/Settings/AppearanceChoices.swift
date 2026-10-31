public import Foundation

/// 「投稿の見た目」で選ぶ選択肢。既定値はプロパティの初期値に書く。
/// 変わったかは既定の値（`AppearanceChoices()`）と比べ、既定に戻すときは既定の値を入れる。項目を並べ直さずに済むよう、1つの値にまとめている。
public struct AppearanceChoices: Codable, Hashable, Sendable {
    /// 投稿の名前の行に、表示名とacctをどう並べるか。
    public var statusNameStyle: StatusNameStyle = .nameAndAcct
    public var statusTimeStyle: StatusTimeStyle = .relative
    /// 名前の上の行で、ブーストした人の表示名とacctをどう並べるか。
    public var contextNameStyle: StatusNameStyle = .nameOnly
    /// 漢字とかなを描く字形。投稿に日本語・中国語・韓国語の言語が付いていれば、そちらを優先する。
    public var glyphLanguage: GlyphLanguage = .automatic
    /// 本文や名前のUnicodeの絵文字を描く絵。
    public var emojiStyle: EmojiStyle = .system
    public var avatarShape: AvatarShape = .roundedSquare
    /// リンクカードのサムネイルを置く端。
    public var linkCardThumbnailSide: LinkCardThumbnailSide = .left
    /// 一覧の投稿の添付ファイルを、本文の下に並べるか、本文の右に小さく出すか。
    public var mediaArrangement: MediaArrangement = .belowBody
    /// 本文の右に重ねた写真を傾ける。オフなら、どの写真もまっすぐに置き、投稿ごとに角度をばらつかせない。
    public var tiltsStackedPhotos = true
    /// 時刻の前に、公開でない投稿の公開範囲の記号を出す。
    public var showsVisibilitySymbol = true
    /// 編集された投稿の時刻の前に「*」を出す。
    public var showsEditedMark = true
    /// リンクカードの一番上に、サイト名を出す。
    public var showsLinkCardSite = true
    /// 名前の上の行の先頭に、ブーストや返信を示す記号を出す。
    public var showsContextSymbol = true
    /// 名前の行の先頭の部分を太字にする。
    public var boldsName = true
    /// アイコンの縁に細い線を引く。
    public var showsAvatarBorder = true
    /// サムネイルに、代替テキストやGIFなどを示すバッジを出す。
    public var showsMediaBadges = true
    /// 投稿にリンクカードを出す。
    public var showsLinkCard = true
    /// リンクカードのタイトルを太字にする。
    public var boldsLinkCardTitle = true
    /// 一覧の投稿と投稿のあいだに区切り線を引く。
    public var showsSeparators = true
    /// 名前の上の行に、ブーストした人のアイコンを出す。
    public var showsBoosterAvatar = true
    /// 返信の名前の上に、返信先を示すラベルを出す。
    public var showsReplyLabel = true
    /// 返信と返信先の行のアイコンを、線でつなぐ。
    public var showsReplyLines = true
    /// アイコンと名前の段の下から、本文やメディアを行の幅いっぱいに置く。オンなら返信をつなぐ線は出さない。決まりはdocs/post-header-layout.mdにある。
    public var wrapsBelowAvatar = false
    /// 名前の表記で名前とハンドルの両方を出すとき、2つ目を2段目に置く。
    public var stacksNameParts = false
    /// 名前の行の右端に、時刻を出す。
    public var showsTime = true
    /// リンクカードに画像を出す。
    public var showsLinkCardImage = true
    /// 一覧で、GIFなどのアニメーションするアイコンを動かす。オフなら最初のコマで止めた版を読む。
    public var animatesAvatars = false
    /// GIFやAPNGのアニメーションするカスタム絵文字を動かす。オフなら最初のコマで止めた版を描く。
    public var animatesCustomEmojis = false
    /// お気に入りとブーストの光を、HDRで描ける画面では白より明るく光らせる。オフならSDRで描く。
    /// メディアの明るさの設定（`mediaDynamicRange`）はメディアに対するものなので、光はそれに従わせず、ここで別に選ぶ。
    public var drawsReactionGlowInHDR = true
    /// お気に入りとブーストの光に、何を示すかのアイコンを添えるか。
    public var reactionGlowIcons: ReactionGlowIcons = .none
    /// お気に入りとブーストの片方だけをしたときに、その色で全幅を光らせる。オフなら、その半分だけを光らせる。
    public var reactionGlowFillsWidthWhenAlone = false
    public var reactionGlowLightFavouriteColor: ReactionGlowLightFavouriteColor = .orange

    public init() {}

    /// 保存したJSONから読む。保存にない項目は既定値にする。項目を足しても、保存してある値を失わないため。
    /// 読めない値（名前を変えた選択肢など）がある項目は既定値に戻し、ほかの項目は保存した値のまま読む。
    public init(stored data: Data?) {
        let fallback = Self()
        guard let data,
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var merged = Self.dictionary(of: fallback)
        else {
            self = fallback
            return
        }
        let base = merged
        merged.merge(saved) { $1 }
        if let choices = Self.decode(merged) {
            self = choices
            return
        }
        var kept = base
        for (key, value) in saved where kept[key] != nil {
            var trial = kept
            trial[key] = value
            if Self.decode(trial) != nil {
                kept = trial
            }
        }
        self = Self.decode(kept) ?? fallback
    }

    /// 保存するJSON。
    public var storedData: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    private static func dictionary(of choices: Self) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: choices.storedData)) as? [String: Any]
    }

    private static func decode(_ dictionary: [String: Any]) -> Self? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
