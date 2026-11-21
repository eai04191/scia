import Foundation

/// 絵文字のパレット。
public enum EmojiPaletteTexts {
    public static let retry = "再試行"
    public static let delete = "削除"
    public static let noEmojis = "並べる絵文字がありません"
    public static let noResults = "見つかりません"
    public static let search = "絵文字を検索"
    public static let loadingCustomEmojis = "カスタム絵文字を読み込んでいます"
    /// 検索欄の隣の、既定の肌の色を選ぶボタンの読み上げ。
    public static let defaultSkinTone = "絵文字の肌の色"
    /// 2人の絵文字の長押しのメニューで、2人それぞれの肌の色を選ぶ段の見出し。
    public static let firstPersonSkinTone = "左の人"
    public static let secondPersonSkinTone = "右の人"
    /// 2人の絵文字の長押しのメニューで、選んだ肌の色の絵文字を入れる。
    public static let insertEmoji = "入力"
}

extension StandardEmojiGroup {
    /// まとまりの名前（`Tools/build-emoji-data.py`の`GROUP_TITLES`）と、まとまりのボタンのSF Symbolsの名前。
    private static let symbolNames: [String: String] = [
        "顔と感情": "face.smiling",
        "人と体": "hand.raised",
        "動物と自然": "pawprint",
        "食べ物と飲み物": "fork.knife",
        "旅行と場所": "car",
        "活動": "soccerball",
        "物": "lightbulb",
        "記号": "number",
        "旗": "flag",
    ]

    /// まとまりのボタンのSF Symbolsの名前。表にない名前ならnil。
    public static func symbolName(forTitle title: String) -> String? {
        symbolNames[title]
    }
}
