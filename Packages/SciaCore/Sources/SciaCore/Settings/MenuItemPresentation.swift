public import Foundation

/// 並びの設定画面に出す、項目の名前とアイコン。
public protocol MenuItemPresentable {
    var title: String { get }
    /// 名前の下に添える説明。
    var note: String? { get }
    var symbolName: String { get }
    /// 「その他」の境目の行の名前と説明とアイコン。境目より下の項目をどこへ入れるかは、項目の種類ごとに違う。
    static var moreBoundaryTitle: String { get }
    static var moreBoundaryNote: String { get }
    static var moreBoundarySymbolName: String { get }
    /// 区切り線を足せるか。
    static var supportsSeparators: Bool { get }
    /// 横並びの区切り線を足せるか。
    static var supportsRowSeparators: Bool { get }
    /// 表示する項目を1つは残すか。残すなら、最後の1つのスイッチを切れなくする。
    static var requiresVisibleItem: Bool { get }
}

/// 長押しのメニューでは、境目より下の項目は「その他」のサブメニューに入る。
extension MenuItemPresentable {
    public static var moreBoundaryTitle: String { "その他" }
    public static var moreBoundaryNote: String { "これより下の項目は、メニューの「その他」の中に入ります" }
    public static var moreBoundarySymbolName: String { "ellipsis.circle" }
    public static var supportsSeparators: Bool { true }
    public static var supportsRowSeparators: Bool { true }
    public static var requiresVisibleItem: Bool { false }
}

/// 長押しのメニューの項目の中身。名前、アイコン、説明はここから決める。
public enum MenuItemContent {
    /// URLに対する共通の項目。名前、アイコン、説明、押したときの動きは共通の項目のものを使う。
    /// - Parameter noteSuffix: このメニューに固有の決まり。共通の説明の後ろに書き足す。
    case url(URLMenuAction, noteSuffix: String? = nil)
    /// このメニューだけの項目。押したときの動きは、メニューを組む側で決める。
    case own(title: String, symbolName: String, note: String? = nil)
}

/// 中身から名前、アイコン、説明を決める項目。項目の種類ごとに、`content`の分岐を1つだけ書く。
/// 分岐に`default`を書かない。項目を足したときに、共通の項目につなぐか、独自の項目にするかをコンパイラに確かめさせるため。
public protocol MenuItemContentProviding: MenuItemPresentable {
    var content: MenuItemContent { get }
}

extension MenuItemContentProviding {
    public var title: String {
        switch content {
        case .url(let action, _): action.title
        case .own(let title, _, _): title
        }
    }

    public var note: String? {
        switch content {
        case .url(let action, let suffix):
            let parts = [action.note, suffix].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: "。")
        case .own(_, _, let note):
            return note
        }
    }

    public var symbolName: String {
        switch content {
        case .url(let action, _): action.symbolName
        case .own(_, let symbolName, _): symbolName
        }
    }

    /// 共通の項目なら、その項目。
    public var urlAction: URLMenuAction? {
        if case .url(let action, _) = content { action } else { nil }
    }
}

extension StatusMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openThread: .own(title: "スレッドを開く", symbolName: "text.bubble", note: "スレッドの中心の投稿と、投稿のない通知では出ません。既定ではタップで開きます")
        case .reply: .own(title: "返信", symbolName: "arrowshape.turn.up.left")
        case .favourite: .own(title: "お気に入り", symbolName: "star")
        case .reblog: .own(title: "ブースト", symbolName: "arrow.2.squarepath")
        case .bookmark: .own(title: "ブックマーク", symbolName: "bookmark")
        case .quote: .own(title: "引用", symbolName: "quote.bubble", note: "引用に対応したサーバーでだけ出ます。引用できない投稿では押せません")
        case .reblogWithVisibility: .own(title: "公開範囲を選んでブースト", symbolName: "arrow.2.squarepath", note: "ブーストしていない、公開かひかえめな公開の投稿でだけ出ます")
        case .pin: .own(title: "プロフィールに固定", symbolName: "pin", note: "ダイレクトではない自分の投稿でだけ出ます")
        case .muteConversation: .own(title: "会話をミュート", symbolName: "bell.slash", note: "自分の投稿、通知、自分へのメンションを含む投稿でだけ出ます")
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc", note: "本文のある投稿でだけ出ます")
        case .selectText: .own(title: "テキストを選択", symbolName: "character.cursor.ibeam", note: "本文を表示している投稿でだけ出ます。引用の囲みと、行数で切っている本文では出ません")
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .editHistory: .own(title: "編集履歴", symbolName: "clock.arrow.circlepath", note: "編集された投稿でだけ出ます")
        case .favouritedBy: .own(title: "お気に入りした人", symbolName: "star.circle", note: "お気に入りされた投稿でだけ出ます")
        case .rebloggedBy: .own(title: "ブーストした人", symbolName: "arrow.2.squarepath.circle", note: "ブーストされた投稿でだけ出ます")
        case .edit: .own(title: "編集", symbolName: "pencil", note: "自分の投稿でだけ出ます")
        case .delete: .own(title: "削除", symbolName: "trash", note: "自分の投稿でだけ出ます")
        case .dismissNotification: .own(title: "通知を削除", symbolName: "xmark.bin", note: "通知でだけ出ます")
        case .hideMedia: .own(title: "メディアを隠す", symbolName: "eye.slash", note: "表示している添付ファイルがある投稿でだけ出ます")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate", note: "本文のある投稿でだけ出ます")
        case .notifyingUser: .own(title: "通知したユーザー", symbolName: "bell", note: "通知でだけ出ます")
        case .author: .own(title: "投稿したユーザー", symbolName: "person.crop.circle")
        case .booster: .own(title: "ブーストしたユーザー", symbolName: "person.crop.circle.badge.plus", note: "ブーストでだけ出ます")
        case .mentionedUsers: .own(title: "メンションされたユーザー", symbolName: "at")
        case .customEmojis: .own(title: "カスタム絵文字", symbolName: "face.smiling", note: "行にカスタム絵文字があるときだけ出ます。絵文字ごとに、画像のメディアのメニューを出します")
        case .hashtags: .own(title: "ハッシュタグ", symbolName: "number", note: "ハッシュタグのある投稿でだけ出ます。ハッシュタグごとに、ハッシュタグのメニューを出します")
        }
    }
}

extension UserMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .profile: .own(title: "プロフィール", symbolName: "person.crop.circle", note: "プロフィール画面では出ません")
        case .mention: .own(title: "メンション", symbolName: "square.and.pencil", note: "投稿欄のカーソルの位置に入れます")
        case .copyHandle: .own(title: "ハンドルをコピー", symbolName: "at", note: "サーバー名を付けた形でコピーします")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .follow: .own(title: "フォロー", symbolName: "person.badge.plus", note: "フォロー中なら外し、リクエスト中なら取り消します。自分には出ません")
        case .showReblogs: .own(title: "ブーストを表示", symbolName: "arrow.2.squarepath", note: "フォローしている相手でだけ出ます")
        case .notify: .own(title: "投稿を通知", symbolName: "bell", note: "フォローしている相手でだけ出ます")
        case .note: .own(title: "メモを追加", symbolName: "note.text", note: "自分にしか見えないメモを書きます。メモがあれば編集します。自分には出ません")
        case .mute: .own(title: "ミュート", symbolName: "speaker.slash", note: "期間を選んでミュートします。ミュート中なら解除します")
        case .block: .own(title: "ブロック", symbolName: "hand.raised", note: "ブロック中なら解除します")
        case .report: .own(title: "通報", symbolName: "flag", note: "投稿のメニューから開くと、その人の投稿なら添えます。自分には出ません")
        }
    }
}

extension LinkMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser, noteSuffix: "リンクをタップしたときと同じです")
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        // 投稿とハッシュタグのURLはMastodonのhttpsのページだが、本文のリンクはほかのスキームもありうる。
        case .openInAppSafari: .url(.openInAppSafari, noteSuffix: "httpとhttpsのリンクでだけ押せます")
        case .openAsProfile: .own(title: "プロフィールとして開く", symbolName: "person.crop.circle", note: "リンク先のプロフィールをサーバーで探して開きます。httpとhttpsのリンクでだけ押せます")
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
        }
    }
}

extension ExternalPostMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .openInBrowser: .url(.openInBrowser, noteSuffix: "囲みをタップしたときと同じです")
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .copyLink: .url(.copyLink)
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc", note: "本文のある投稿でだけ出ます")
        case .share: .url(.share)
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate", note: "本文のある投稿でだけ出ます")
        }
    }
}

extension ProfileTextMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .copyText: .own(title: "テキストをコピー", symbolName: "doc.on.doc", note: "補足情報では内容だけをコピーします")
        case .copyLabel: .own(title: "ラベルをコピー", symbolName: "tag", note: "補足情報の行でだけ出ます")
        case .systemTranslate: .own(title: "翻訳", symbolName: "translate", note: "補足情報では内容だけを訳します")
        case .customEmojis: .own(title: "カスタム絵文字", symbolName: "face.smiling", note: "長押しした文章にカスタム絵文字があるときだけ出ます。絵文字ごとに、画像のメディアのメニューを出します")
        }
    }
}

extension HashtagMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .timeline: .own(title: "すべての投稿", symbolName: "number", note: "ハッシュタグのタイムラインを開きます。ハッシュタグをタップしたときと同じです")
        case .mute: .own(title: "ミュート", symbolName: "speaker.slash", note: "このハッシュタグの付いた投稿を、サーバーのフィルターで隠します。ミュート中なら解除します")
        case .accountStatuses: .own(title: "投稿したユーザーの投稿", symbolName: "person.crop.square", note: "このハッシュタグの付いた、投稿したユーザーの投稿を開きます。プロフィールではその人の投稿です。メニューでは「@名前の投稿」と出ます")
        case .openInBrowser: .url(.openInBrowser)
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .copyLink: .url(.copyLink)
        case .share: .url(.share)
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

    /// 並びの設定画面で、名前の下に添える説明。メニューに固有の決まりがあれば、メニューの側でこれに書き足す。
    public var note: String? {
        switch self {
        case .openInBrowser: "設定の開く場所で開きます"
        case .openInDefaultBrowser: "設定の開く場所にかかわらず、既定のブラウザで開きます"
        case .openInAppSafari: "設定の開く場所にかかわらず、アプリ内のSafariで開きます"
        case .copyLink, .share: nil
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
        case .bookmarks: "ブックマーク"
        case .favourites: "お気に入り"
        case .scheduled: "予約投稿"
        case .list(_, let title): title
        case .hashtag(let name): "#\(name)"
        case .accountHashtag(_, _, let name, let title): title.isEmpty ? "#\(name)" : title
        }
    }

    /// ユーザーのハッシュタグは、同じハッシュタグの項目と見分けられるよう、誰の投稿かを添える。
    public var note: String? {
        guard case .accountHashtag(_, let acct, let name, let title) = self else { return nil }
        return title.isEmpty ? "@\(acct)の投稿" : "#\(name)、@\(acct)の投稿"
    }

    public var symbolName: String {
        switch self {
        case .home: "house"
        case .local: "person.2"
        case .federated: "globe"
        case .notifications: "bell"
        case .bookmarks: "bookmark"
        case .favourites: "star"
        case .scheduled: "clock"
        case .list: "list.bullet"
        case .hashtag: "number"
        case .accountHashtag: "number.square"
        }
    }

    public static var moreBoundaryTitle: String { "切り替えタブ" }
    public static var moreBoundaryNote: String { "これより下の項目は、タブバーの最後のタブにまとめ、見出しのメニューで切り替えます" }
    public static var moreBoundarySymbolName: String { "rectangle.stack" }
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
        }
    }

    public var note: String? {
        switch self {
        case .spoiler: "添付があれば、添付も閲覧注意にします。注意書きを空にすると、閲覧注意だけを付けます"
        case .poll: "本文の下に投票の欄を出します。メディアの添付とは一緒に付けられません"
        case .schedule: "日時を選んで、その日時にサーバーから投稿します。編集では付けられません"
        case .language: "投稿に付ける言語を選びます。既定と違う言語を選んでいる間は、言語のコードを出します"
        case .linkTitle: "本文のURLを選ぶと、リンク先のページのタイトルを読み、URLの前に入れます。URLが行の頭にあれば、タイトルを1行にします"
        case .customEmoji: "サーバーのカスタム絵文字を並べたシートを出します。もう一度押すとキーボードに戻ります"
        case .customize: "この並びを変える画面を開きます。隠しても、設定の「投稿欄のボタン」から変えられます"
        case .mention: "本文のカーソルの位置に半角の@を入れ、返信先の人や前にメンションした人を候補に出します"
        case .hashtag: "本文のカーソルの位置に半角の#を入れ、プロフィールのタグや最近使ったタグを候補に出します"
        default: nil
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
        }
    }

    public static var moreBoundaryTitle: String { "＋ボタン" }
    public static var moreBoundaryNote: String { "これより上の項目は＋の中に入れ、下の項目はボタンの行に＋の右から並べます。行に入りきらない項目は＋の中に入ります" }
    public static var moreBoundarySymbolName: String { "plus.circle" }
    /// ＋のメニューは項目が少なく、ボタンの行は横並びの区切り線に関わらず横に並ぶため、足させない。
    public static var supportsRowSeparators: Bool { false }
}

extension MediaMenuItem: MenuItemContentProviding {
    public var content: MenuItemContent {
        switch self {
        case .open: .own(title: "開く", symbolName: "arrow.up.left.and.arrow.down.right", note: "ビューアでは出ません")
        case .share: .own(title: "共有", symbolName: "square.and.arrow.up", note: "メディアのファイルを共有します")
        case .saveToPhotos: .own(title: "写真に保存", symbolName: "square.and.arrow.down", note: "画像、動画、GIFでだけ出ます")
        case .altText: .own(title: "代替テキスト", symbolName: "text.below.photo", note: "代替テキストが付いているときだけ出ます")
        case .translateText: .own(title: "画像の文字を翻訳", symbolName: "translate", note: "ビューアで画像から文字を読み取れたときだけ出ます")
        case .copyLink: .url(.copyLink, noteSuffix: "メディアのファイルのURLをコピーします")
        case .openInBrowser: .url(.openInBrowser, noteSuffix: "メディアのファイルを開きます")
        case .openInDefaultBrowser: .url(.openInDefaultBrowser)
        case .openInAppSafari: .url(.openInAppSafari)
        case .status: .own(title: "投稿", symbolName: "text.bubble", note: "投稿のメニューをサブメニューで出します。ビューアとプロフィールの画像では出ません")
        case .info: .own(title: "メディアの情報", symbolName: "info.circle", note: "解像度、形式、フレームレート、長さ、ビットレートのうち分かるものを出します")
        }
    }
}
