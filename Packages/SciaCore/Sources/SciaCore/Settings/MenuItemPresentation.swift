public import Foundation

/// 並びの設定画面に出す、項目の名前とアイコン。
public protocol MenuItemPresentable {
    var title: String { get }
    /// 名前だけでは同じ並びのほかの項目と見分けられないときに、名前の下に添える文字。
    var detail: String? { get }
    var symbolName: String { get }
    /// 並びの画面で、「その他」の境目の前と後ろに分けた節の見出しと、見出しだけでは伝わらないことを添える注記。
    /// 境目の前と後ろの項目をどこへ入れるかは、項目の種類ごとに違う。
    static var mainSectionTitle: String { get }
    static var mainSectionNote: String? { get }
    static var moreSectionTitle: String { get }
    static var moreSectionNote: String? { get }
    /// 区切り線を足せるか。
    static var supportsSeparators: Bool { get }
    /// 横並びの区切り線を足せるか。
    static var supportsRowSeparators: Bool { get }
    /// 表示する項目を1つは残すか。残すなら、最後の1つのスイッチを切れなくする。
    static var requiresVisibleItem: Bool { get }
}

/// 長押しのメニューでは、境目より下の項目は「その他」のサブメニューに入る。
extension MenuItemPresentable {
    public var detail: String? { nil }
    public static var mainSectionTitle: String { "メニュー" }
    public static var mainSectionNote: String? { nil }
    public static var moreSectionTitle: String { "その他" }
    public static var moreSectionNote: String? { nil }
    public static var supportsSeparators: Bool { true }
    public static var supportsRowSeparators: Bool { true }
    public static var requiresVisibleItem: Bool { false }
}

/// 長押しのメニューの項目の中身。名前とアイコンはここから決める。
public enum MenuItemContent {
    /// URLに対する共通の項目。名前、アイコン、押したときの動きは共通の項目のものを使う。
    case url(URLMenuAction)
    /// このメニューだけの項目。押したときの動きは、メニューを組む側で決める。
    case own(title: String, symbolName: String)
}

/// 中身から名前とアイコンを決める項目。項目の種類ごとに、`content`の分岐を1つだけ書く。
/// 分岐に`default`を書かない。項目を足したときに、共通の項目につなぐか、独自の項目にするかをコンパイラに確かめさせるため。
public protocol MenuItemContentProviding: MenuItemPresentable {
    var content: MenuItemContent { get }
}

extension MenuItemContentProviding {
    public var title: String {
        switch content {
        case .url(let action): action.title
        case .own(let title, _): title
        }
    }

    public var symbolName: String {
        switch content {
        case .url(let action): action.symbolName
        case .own(_, let symbolName): symbolName
        }
    }

    /// 共通の項目なら、その項目。
    public var urlAction: URLMenuAction? {
        if case .url(let action) = content { action } else { nil }
    }
}

extension StatusMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openThread: .own(title: "スレッドを開く", symbolName: "text.bubble")
        case .reply: .own(title: "返信", symbolName: "arrowshape.turn.up.left")
        case .favourite: .own(title: "お気に入り", symbolName: "star")
        case .reblog: .own(title: "ブースト", symbolName: "arrow.2.squarepath")
        case .bookmark: .own(title: "ブックマーク", symbolName: "bookmark")
        case .quote: .own(title: "引用", symbolName: "quote.bubble")
        case .emojiReaction: .own(title: "リアクション", symbolName: "face.smiling")
        case .reblogWithVisibility: .own(title: "公開範囲を選んでブースト", symbolName: "arrow.2.squarepath")
        case .otherAccounts: .own(title: "別のアカウントで", symbolName: "person.2")
        case .pin: .own(title: "プロフィールに固定", symbolName: "pin")
        case .muteConversation: .own(title: "会話をミュート", symbolName: "bell.slash")
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc")
        case .selectText: .own(title: "テキストを選択", symbolName: "character.cursor.ibeam")
        case .share: .url(.share)
        case .select: .own(title: "選択", symbolName: "checkmark.circle")
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .editHistory: .own(title: "編集履歴", symbolName: "clock.arrow.circlepath")
        case .favouritedBy: .own(title: "お気に入りした人", symbolName: "star.circle")
        case .rebloggedBy: .own(title: "ブーストした人", symbolName: "arrow.2.squarepath.circle")
        case .edit: .own(title: "編集", symbolName: "pencil")
        case .delete: .own(title: "削除", symbolName: "trash")
        case .redraft: .own(title: "削除して書き直す", symbolName: "square.and.pencil")
        case .dismissNotification: .own(title: "通知を削除", symbolName: "xmark.bin")
        case .hideMedia: .own(title: "メディアを隠す", symbolName: "eye.slash")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate")
        case .notifyingUser: .own(title: "通知したユーザー", symbolName: "bell")
        case .author: .own(title: "投稿したユーザー", symbolName: "person.crop.circle")
        case .booster: .own(title: "ブーストしたユーザー", symbolName: "person.crop.circle.badge.plus")
        case .mentionedUsers: .own(title: "メンションされたユーザー", symbolName: "at")
        case .customEmojis: .own(title: "カスタム絵文字", symbolName: "face.smiling")
        case .apiResponse: .own(title: "APIの応答", symbolName: "curlybraces")
        case .hashtags: .own(title: "ハッシュタグ", symbolName: "number")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension UserMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .profile: .own(title: "プロフィール", symbolName: "person.crop.circle")
        case .mention: .own(title: "メンション", symbolName: "square.and.pencil")
        case .copyHandle: .own(title: "ハンドルをコピー", symbolName: "at")
        case .copyUsername: .own(title: "ユーザー名をコピー", symbolName: "person")
        case .copyServer: .own(title: "サーバーをコピー", symbolName: "server.rack")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .follow: .own(title: "フォロー", symbolName: "person.badge.plus")
        case .addToList: .own(title: "リストに追加", symbolName: "text.badge.plus")
        case .showReblogs: .own(title: "ブーストを表示", symbolName: "arrow.2.squarepath")
        case .notify: .own(title: "投稿を通知", symbolName: "bell")
        case .endorse: .own(title: "プロフィールで紹介", symbolName: "person.text.rectangle")
        case .note: .own(title: "メモを追加", symbolName: "note.text")
        case .mute: .own(title: "ミュート", symbolName: "speaker.slash")
        case .block: .own(title: "ブロック", symbolName: "hand.raised")
        case .report: .own(title: "通報", symbolName: "flag")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension LinkMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        // 投稿とハッシュタグのURLはMastodonのhttpsのページだが、本文のリンクはほかのスキームもありうる。
        case .openInAppSafari: .url(.openInAppSafari)
        case .openAsProfile: .own(title: "プロフィールとして開く", symbolName: "person.crop.circle")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension ExternalPostMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc")
        case .share: .url(.share)
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension ProfileTextMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc")
        case .copyLabel: .own(title: "ラベルをコピー", symbolName: "tag")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate")
        case .customEmojis: .own(title: "カスタム絵文字", symbolName: "face.smiling")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension HashtagMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .timeline: .own(title: "すべての投稿", symbolName: "number")
        case .follow: .own(title: "フォロー", symbolName: "plus.circle")
        case .mute: .own(title: "ミュート", symbolName: "speaker.slash")
        case .feature: .own(title: "プロフィールで紹介", symbolName: "person.text.rectangle")
        case .accountStatuses: .own(title: "投稿したユーザーの投稿", symbolName: "person.crop.square")
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

/// 投稿、ユーザー、リンク、ハッシュタグのメニューに共通の、ページのURLに対する項目。
/// どのメニューに置くかはメニューごとの項目の一覧で決め、ここでは名前とアイコンと、押せる状態かどうかと、開く項目がどこで開くかをそろえる。
public enum URLMenuAction {
    case copyLink
    case share
    /// 開く場所の設定に従って開く。リンクをタップしたときと同じ。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari

    public var title: String {
        switch self {
        case .copyLink: "リンクをコピー"
        case .share: "共有"
        case .openInBrowser: "ブラウザで開く"
        case .openInDefaultBrowser: "既定のブラウザで開く"
        case .openInAppSafari: "アプリ内のSafariで開く"
        }
    }

    public var symbolName: String {
        switch self {
        case .copyLink: "link"
        case .share: "square.and.arrow.up"
        case .openInBrowser: "safari"
        case .openInDefaultBrowser: "arrow.up.forward.app"
        case .openInAppSafari: "rectangle.bottomhalf.inset.filled"
        }
    }

    /// 開く項目で`url`を開く場所。その場所で開けなければnil。
    public func browser(for url: URL, following setting: LinkBrowser) -> LinkBrowser? {
        switch self {
        case .openInBrowser: setting.browser(for: url)
        case .openInDefaultBrowser: .external
        // アプリ内のSafariは、httpとhttps以外のURLを渡すと例外で落ちる。黙って既定のブラウザで開くと選んだ場所と違うため、押せないようにする。
        case .openInAppSafari: LinkBrowser.inApp.browser(for: url) == .inApp ? .inApp : nil
        case .copyLink, .share: nil
        }
    }
}

/// タブバーと、タブの並びの設定画面に出す名前とアイコン。
extension TabItem: MenuItemPresentable {
    public var title: String {
        switch self {
        case .home: "ホーム"
        case .local: "ローカル"
        case .federated: "連合"
        case .notifications: "通知"
        case .search: "検索"
        case .bookmarks: "ブックマーク"
        case .favourites: "お気に入り"
        case .scheduled: "予約投稿"
        case .followedTags: "フォロー中のハッシュタグ"
        case .list(_, let title): title
        case .hashtag(let name, let title): title.isEmpty ? "#\(name)" : title
        case .accountHashtag(_, _, let name, let title): title.isEmpty ? "#\(name)" : title
        // ほかのサーバーの人のハンドルは長く、タブバーの幅に収まらないため、`@`より前だけを出す。
        case .profile(_, let acct, let title): title.isEmpty ? "@\(acct.prefix { $0 != "@" })" : title
        }
    }

    /// ハッシュタグは、名前を付けたら元のハッシュタグを添える。
    /// ユーザーのハッシュタグは、同じハッシュタグの項目と見分けられるよう、誰の投稿かを添える。
    /// プロフィールは、名前だけでは分からないハンドル（ほかのサーバーの人のサーバー、付けた名前のときはハンドル全体）を添える。
    public var detail: String? {
        switch self {
        case .hashtag(let name, let title): title.isEmpty ? nil : "#\(name)"
        case .accountHashtag(_, let acct, let name, let title): title.isEmpty ? "@\(acct)の投稿" : "#\(name)、@\(acct)の投稿"
        case .profile(_, let acct, let title): title.isEmpty && !acct.contains("@") ? nil : "@\(acct)"
        default: nil
        }
    }

    public var symbolName: String {
        switch self {
        case .home: "house"
        case .local: "person.2"
        case .federated: "globe"
        case .notifications: "bell"
        case .search: "magnifyingglass"
        case .bookmarks: "bookmark"
        case .favourites: "star"
        case .scheduled: "clock"
        case .followedTags: "tag"
        case .list: "list.bullet"
        case .hashtag: "number"
        case .accountHashtag: "number.square"
        case .profile: "person.crop.circle"
        }
    }

    public static var mainSectionTitle: String { "タブバー" }
    public static var moreSectionTitle: String { "切り替えタブ" }
    public static var moreSectionNote: String? { "タブバーの最後のタブにまとめて表示されます。" }
    /// タブは1つずつ並ぶだけで、まとまりを分けるものがないため、区切り線を足させない。
    public static var supportsSeparators: Bool { false }
    public static var supportsRowSeparators: Bool { false }
    /// タブバーを空にできないため、最後の1つは無効にさせない。
    public static var requiresVisibleItem: Bool { true }
}

/// 投稿欄のボタンと＋のメニュー、並びの設定画面に出す、項目の名前とアイコン。
extension ComposeToolItem: MenuItemPresentable {
    public var title: String {
        switch self {
        case .visibility: "公開範囲"
        case .media: "メディアを添付"
        case .expand: "広げて書く"
        case .spoiler: "注意書き"
        case .poll: "投票"
        case .schedule: "予約"
        case .language: "言語"
        case .linkTitle: "リンクにタイトルを付ける"
        case .customEmoji: "カスタム絵文字"
        case .customize: "カスタマイズ"
        case .mention: "メンション"
        case .hashtag: "ハッシュタグ"
        case .discardDraft: "下書きを捨てる"
        }
    }

    public var symbolName: String {
        switch self {
        case .visibility: "globe"
        case .media: "photo.on.rectangle"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .spoiler: "exclamationmark.triangle"
        case .poll: "chart.bar.doc.horizontal"
        case .schedule: "clock"
        case .language: "character.bubble"
        case .linkTitle: "link.badge.plus"
        case .customEmoji: "face.smiling"
        case .customize: "slider.horizontal.3"
        case .mention: "at"
        case .hashtag: "number"
        case .discardDraft: "trash"
        }
    }

    public static var mainSectionTitle: String { "＋のメニュー" }
    public static var moreSectionTitle: String { "ツールバー" }
    public static var moreSectionNote: String? { "入りきらない項目は＋のメニューに表示されます。" }
    /// ＋のメニューは項目が少なく、ツールバーは横並びの区切り線に関わらず横に並ぶため、足させない。
    public static var supportsRowSeparators: Bool { false }
}

extension ReactionMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .toggle: .own(title: "リアクションする・外す", symbolName: "face.smiling")
        case .reactedBy: .own(title: "リアクションした人", symbolName: "person.2")
        case .open: .own(title: "開く", symbolName: "arrow.up.left.and.arrow.down.right")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}

extension MediaMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .open: .own(title: "開く", symbolName: "arrow.up.left.and.arrow.down.right")
        case .share: .own(title: "共有", symbolName: "square.and.arrow.up")
        case .saveToPhotos: .own(title: "写真に保存", symbolName: "square.and.arrow.down")
        case .altText: .own(title: "代替テキスト", symbolName: "text.below.photo")
        case .translateText: .own(title: "画像の文字を翻訳", symbolName: "translate")
        case .copyLink: .url(.copyLink)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .status: .own(title: "投稿", symbolName: "text.bubble")
        case .info: .own(title: "メディアの情報", symbolName: "info.circle")
        case .customize: .own(title: "カスタマイズ", symbolName: "slider.horizontal.3")
        }
    }
}
