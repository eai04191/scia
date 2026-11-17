public import Foundation

/// 設定の画面と、アカウントの画面から開く画面（投稿のデフォルト、フィルター、通知のフィルタリング）に出す文言。どのUIも同じ文言で出すため、画面を描く側では書かない。
/// 画面の題と行の名前は`SettingsPage`と`SettingsItem`に、見た目の項目の名前は`AppearanceCatalog`と`AppearanceChoice`にある。
public enum SettingsTexts {
    /// シートを閉じるボタン。
    public static let done = "完了"
    public static let cancel = "キャンセル"
    /// スワイプして出す削除のボタンと、削除を確かめるアラートのボタン。
    public static let delete = "削除"
    /// サーバーから読み込めなかったときの、空の画面の見出し。
    public static let loadFailed = "読み込めませんでした"
    /// サーバーから読み込めなかったときの、空の画面のボタン。
    public static let reload = "再読み込み"
    /// リストを作るボタン。タブの並びの画面とアカウントの画面のリストで使う。
    public static let createList = "リストを作成"

    /// 件数の値。
    public static func count(_ count: Int) -> String {
        "\(count)件"
    }

    /// メディアのキャッシュの件数。ほかの件数と違い、桁区切りを付ける。
    /// iOSでは、この件数だけSwiftUIの`Text`に数を埋めて出していて、`Text`が桁区切りを付けていたため。
    public static func cachedCount(_ count: Int) -> String {
        "\(count.formatted())件"
    }

    /// 情報の画面。
    public enum About {
        /// ビルドの行を続けてタップしてデバッグメニューを切り替えたときのアラート。
        public static func developerModeChanged(isEnabled: Bool) -> String {
            isEnabled ? "デバッグメニューをオンにしました" : "デバッグメニューをオフにしました"
        }

        /// ビルドの情報の行の、値をコピーする操作。
        public static let copy = "コピー"
        /// ビルドの情報の行の、すべての行をまとめてコピーする操作。
        public static let copyAll = "すべてコピー"
    }

    /// 謝辞の画面。
    public enum Acknowledgments {
        public static let website = "ウェブサイト"
        public static let account = "アカウント"
    }

    /// ライセンスの画面。
    public enum Licenses {
        public static let source = "配布元"

        /// ライセンスの全文を開くリンク。
        public static func licenseLink(name: String) -> String {
            "ライセンス（\(name)）"
        }
    }

    /// アプリのアイコンの画面。
    public enum AppIcon {
        /// 選択肢を並べるピッカーの名前。ラベルは隠すので、読み上げで使う。
        public static let picker = "アイコン"
        public static let failureLead = "アイコンを変更できませんでした。"
        /// 主アイコンの名前。
        public static let standard = "青地に白"
        /// 白地のアイコンの名前。
        public static let light = "白地に青"
    }

    /// 表示の画面。
    public enum Display {
        /// iOS 26.0で、選んだアクセントカラーが選択中のタブを見分けにくくするときに、アクセントカラーの節の下に出す説明。
        public static let accentColorObscuresSelectedTab = "iOS 26.0ではこのカラーを使用すると選択中のタブがほかのタブと区別しにくくなります。iOS 26.1以降での使用を推奨します。"
        /// ステータスバーの通知を出せない機種で、切り替えの下に出す説明。
        public static let statusBarTickerUnavailable = "このiPhoneでは使えません。"
    }

    /// タブの並びの画面。
    public enum Tabs {
        public static let showsCustomize = "メニューに“カスタマイズ”を表示"
        public static let showsCustomizeFooter = "切り替えタブのメニューに、この画面を開く“カスタマイズ”を表示します。"
    }

    /// メニューやタブの並びを並べ替える画面。
    public enum MenuLayout {
        public static let addSeparator = "区切り線を追加"
        public static let addRowSeparator = "横並びを追加"
        public static let reset = "デフォルトの並びに戻す"
        /// 節に項目がないときの行。
        public static let empty = "なし"
        /// 横並びに入る項目の読み上げのヒント。
        public static let rowGroupHint = "メニューで横に並びます。"
        /// 区切り線の行に出す名前。読み上げにも使う。
        public static let separator = "区切り線"
        /// 横並びの区切り線の行の読み上げ。
        public static let rowSeparatorAccessibilityLabel = "横並びの区切り線"
    }

    /// ストレージの画面。
    public enum Storage {
        public static let removeFailureLead = "消去できませんでした。"
        /// アプリの大きさの行の下に出す説明。
        public static let appSizeFooter = "このiPhoneに入っているアプリのファイルを合計した大きさです。iPhoneの設定の“Appのサイズ”とは数え方が違い、ずれることがあります。"
        public static let measuring = "測っています"
        /// 消去を確かめるダイアログのボタン。
        public static let remove = "消去"
    }

    /// ストレージのメディアのキャッシュの画面。
    public enum MediaCache {
        public static let loading = "読み込んでいます"
        public static let openFailed = "開けませんでした"
        /// 開こうとしたファイルが、開く前にキャッシュから消えていたときの理由。
        public static let removedFromCache = "キャッシュから削除されていました。"
    }

    /// 投稿の見た目と通知の見た目の画面。
    public enum Appearance {
        /// 投稿の見た目の、すべてを戻すボタンの下に出す説明。
        public static let footer = "文字の大きさはiPhoneの文字サイズが標準のときの大きさです。本文はiPhoneの文字サイズに合わせて伸び縮みし、ほかの文字は本文との差を保ちます。"
        /// 通知の見た目の、分類の下に出す説明。
        public static let notificationFooter = "メンションなどの投稿の見た目と行の余白やアイコンの列の幅は、“表示”の“投稿”に従います。文字の大きさは投稿の本文との差を保ちます。"
        /// デフォルトから変えた項目に添えるインジケーターの読み上げ。
        public static let modified = "変更あり"
        /// 項目をデフォルトの値に戻すメニューの項目。
        public static let resetItem = "デフォルトに戻す"
        /// スレッドで開いた投稿では、表示しない設定にした部品も出すかのスイッチ。
        public static let revealsAllPartsInThread = "スレッドで開いた投稿はすべて表示"
        /// `revealsAllPartsInThread`の下に出す説明。
        public static let revealsAllPartsInThreadFooter = "表示しない部品も、スレッドで開いた投稿では表示します。"
    }

    /// アプリ内のSafariの高さを選ぶシート。
    public enum InAppBrowserHeight {
        public static let topInset = "上の余白"
        public static let reset = "標準に戻す"
        public static let footer = "シートを上下にドラッグしてリンクを開いたときの高さを調整します。"
        public static let opensFullScreen = "最初から全画面で開く"
    }

    /// 自動翻訳の画面。
    public enum AutoTranslation {
        /// 自動翻訳を切り替えるスイッチ。
        public static let toggle = "自動翻訳"
        public static let target = "翻訳先"

        /// 翻訳先の選択肢のうち、端末の言語に訳すもの。
        public static func deviceLanguage(name: String) -> String {
            "デバイスの言語（\(name)）"
        }

        public static let mode = "翻訳モード"
        /// 翻訳モードの選択肢のうち、Apple Intelligenceを使わないもの。
        public static let standardMode = "標準"
        public static let excludedUsers = "自動翻訳しないユーザー"

        /// 端末にある言語の節の見出し。Apple Intelligenceのモデルで訳しているときは、言語ごとのダウンロードがないので、訳す元の言語として出す。
        public static func installedHeader(usesSharedModel: Bool) -> String {
            usesSharedModel ? "翻訳元" : "ダウンロード済み"
        }

        public static let removeLanguageFooter = "言語は“設定”>“アプリ”>“翻訳”>“言語”で削除できます。"

        /// 言語をダウンロードするボタンの読み上げ。
        public static func download(languageName: String) -> String {
            "\(languageName)をダウンロード"
        }

        public static let downloadable = "ダウンロード可能な言語"
    }

    /// アカウントの画面。
    public enum Account {
        public static let announcements = "サーバーのお知らせ"

        /// サーバーのお知らせの行の、未読の数。
        public static func unreadAnnouncements(count: Int) -> String {
            "未読\(count)件"
        }

        public static let profile = "プロフィール"
        public static let lists = "リスト"
        public static let logOut = "ログアウト"
        /// リストの画面で、リストがないときの見出し。
        public static let noLists = "リストはありません"
    }

    /// 投稿のデフォルトの画面。
    public enum PostingDefaults {
        public static let title = "投稿のデフォルト"
        public static let visibility = "公開範囲"
        public static let quotePolicy = "引用できる人"
        public static let language = "言語"
        /// 言語を決めていないときの、言語の行の値。
        public static let languageUnset = "サーバーに任せる"
        public static let sensitive = "メディアを閲覧注意にする"
        public static let sensitiveFooter = "メディアを添付すると、注意書きの欄を開きます。"
    }

    /// 通知のフィルタリングの画面。
    public enum NotificationFiltering {
        public static let title = "通知のフィルタリング"
        public static let unsupported = "このサーバーでは使えません"
        public static let unsupportedDescription = "通知のフィルタリングはMastodon 4.3から使えます。"
        /// 「無視」にしてよいか確かめるダイアログのボタン。
        public static let setDrop = "“無視”に設定"
        /// 「無視」にしてよいか確かめるダイアログで、代わりに「保留」にするボタン。
        public static let setFilter = "“保留”に設定"
        public static let dropMessage = "無視した通知は作成されないため、あとから表示できません。“保留”にすると保留中の通知で個別に確認できます。"
    }

    /// フィルターの画面と、フィルターを作るか変える画面。
    public enum Filters {
        public static let title = "フィルター"
        public static let create = "フィルターを作成"
        public static let empty = "フィルターはありません"
        public static let namePlaceholder = "名前"
        /// フィルターを当てる場所の節の見出し。
        public static let contexts = "対象"
        /// 一致した投稿をどう扱うかを選ぶピッカー。
        public static let action = "一致した投稿"
        /// キーワードでなく投稿を指して足したものの数の行。
        public static let statuses = "個別に追加した投稿"
        public static let deleteFilter = "フィルターを削除"

        /// 編集の画面の題。
        public static func editorTitle(isNew: Bool) -> String {
            isNew ? "新規フィルター" : "フィルターを編集"
        }

        public static let discardChanges = "変更を破棄"
        public static let save = "保存"
        public static let saveFailed = "フィルターを保存できませんでした"
        public static let keywordPlaceholder = "キーワードまたはフレーズ"
        public static let wholeWord = "単語全体に一致"
        public static let keywords = "キーワード"
        public static let addKeyword = "キーワードを追加"
        public static let expiry = "期限"

        /// 消してよいか確かめるアラートの題。
        public static func deleteConfirmation(title: String) -> String {
            "フィルター“\(title)”を削除しますか？"
        }

        public static let deleteFailed = "フィルターを削除できませんでした"
    }

    /// 接続の状態の画面。開発者が見る画面なので、ポーリングなどの用語をそのまま使う。
    public enum Connection {
        public static let server = "サーバー"
        public static let version = "バージョン"
        /// サーバーの版をまだ読めていないときの値。
        public static let versionUnknown = "読み込めていません"
        public static let streaming = "ストリーミング"
        public static let rateLimit = "レート制限"

        /// レート制限の行の値。自動の通信を止めていれば、明ける時刻を出す。
        public static func rateLimitValue(pausedUntil: Date?) -> String {
            pausedUntil.map { "\($0.formatted(date: .omitted, time: .standard))まで" } ?? "なし"
        }

        public static let rateLimitFooter = "自動の読み込みを控えています。"
        public static let disabledFeatures = "使っていない機能"

        /// 使っていない機能の行の値。止めたときのステータスと時刻を出す。
        public static func disabledFeatureValue(statusCode: Int, date: Date) -> String {
            "HTTP \(statusCode)・\(date.formatted(date: .omitted, time: .shortened))"
        }

        /// サーバーが処理できない画像の形式の行の名前。
        public static func imageTypeTitle(mimeType: String) -> String {
            let format = switch mimeType {
            case "image/heic": "HEIC"
            case "image/heif": "HEIF"
            case "image/avif": "AVIF"
            default: mimeType
            }
            return "\(format)の画像を送る"
        }

        /// サーバーが処理できない画像の形式の行の値。どの版のサーバーで覚えたかを添える。
        public static func unprocessableFormatValue(serverVersion: String) -> String {
            "JPEGで送っています・\(serverVersion.isEmpty ? "版が不明" : serverVersion)"
        }

        public static let recentFailures = "最近のエラー"

        /// 最近のエラーの行の、時刻と失敗の種類。
        public static func failureDetail(date: Date, kind: String) -> String {
            "\(date.formatted(date: .omitted, time: .standard))・\(kind)"
        }

        public static let dropped = "読めなかった項目"
        public static let droppedFooter = "アプリを起動してからサーバーから届いた内容のうち読めなかった投稿や通知などの数です。"
    }
}

extension OptionalFeature {
    /// 接続の状態の画面の、使っていない機能の行の名前。
    public var title: String {
        switch self {
        case .markers: "既読位置の保存"
        case .preferences: "アカウントの設定（公開範囲のデフォルトなど）"
        case .instanceV2: "サーバーの設定（v2）"
        case .multipleStatuses: "リンクカードの取り直し"
        case .multipleAccounts: "メンションされたユーザーのアイコン"
        case .groupedNotifications: "通知のまとめ表示"
        case .notificationFilter: "保留中の通知"
        }
    }
}

extension StreamingSubscription {
    /// 受信中のタイムラインの画面に出す名前。タブの名前にそろえる。
    /// - Parameter listTitles: リストのIDから、タブの並びに保存したリストの名前を引く。並びにないリストは名前を出さない。
    public func title(listTitles: [String: String]) -> String {
        switch stream {
        case "user": "ホームと通知"
        case "public:local": TabItem.local.title
        case "public": TabItem.federated.title
        case "list": list.flatMap { listTitles[$0] }.map { "リスト“\($0)”" } ?? "リスト"
        case "hashtag": tag.map { "#\($0)" } ?? "ハッシュタグ"
        default: stream
        }
    }
}

extension ServerFilter {
    /// フィルターの画面の行に出す、扱いと期限。
    public func rowDetail(now: Date) -> String {
        var parts = [filterAction.title]
        if let expiresAt, expiresAt <= now {
            parts.append("期限切れ")
        } else if let expiresAt {
            parts.append("\(expiresAt.formatted(date: .abbreviated, time: .shortened))まで")
        }
        return parts.joined(separator: "・")
    }
}

extension AppearanceValue.Unit {
    /// 値の欄の数に添える単位。割合には添えない。
    public var title: String? {
        switch self {
        case .ratio: nil
        case .lines: "行"
        case .count: "個"
        case .point, .bodyTextOffset, .textOffset: "pt"
        }
    }
}

extension AppearanceValue {
    /// 割合の項目の、値の向きの説明。割合の意味は項目ごとに違うので、単位ではなく項目で決める。
    public var ratioNote: String? {
        switch id {
        case AppearanceCatalog.mediaTallestAspectRatio.id: "小さいほど縦長のまま表示"
        case AppearanceCatalog.mediaWidestAspectRatio.id: "大きいほど横長のまま表示"
        case AppearanceCatalog.avatarCornerRatio.id: "0.5で円になる"
        case AppearanceCatalog.quoteIndent.id: "1で本文の1文字分"
        case AppearanceCatalog.linkCardImageWidthRatio.id: "画像はカードの高さの正方形より広くならない"
        // カスタム絵文字の割合の基準（普通の絵文字を文字の大きさのまま描いたときの大きさ）は見出しに書かず、1がどの大きさかで伝える。普通の絵文字は、1でいつもの大きさなのが倍率から分かるので添えない。
        case AppearanceCatalog.customEmojiScale.id, AppearanceCatalog.nameCustomEmojiScale.id: "1で絵文字と同じ大きさ"
        default: nil
        }
    }

    /// 項目の名前の下に出す、今の値の説明。
    public func note(for value: Double) -> String? {
        switch unit {
        case .point: nil
        case .lines: value == 0 ? (self == AppearanceCatalog.bodyTruncationThreshold ? "切らない" : "表示しない") : nil
        case .count: self == AppearanceCatalog.emojiOnlyLimit && value == 0 ? "大きくしない" : nil
        case .ratio: ratioNote
        case .bodyTextOffset: value == 0 ? "標準" : "標準\(Self.signedNumberText(value))"
        case .textOffset: value == 0 ? "本文と同じ" : "本文\(Self.signedNumberText(value))"
        }
    }

    /// 値の欄に出す数。整数なら小数点を付けず、そうでなければ小数点以下1桁で出す。
    public static func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func signedNumberText(_ value: Double) -> String {
        (value > 0 ? "+" : "−") + numberText(abs(value))
    }
}

extension MenuRowSize {
    /// 横に並べる大きさの名前。区切り線の行のメニューの選択肢と、読み上げの値に使う。
    public var title: String {
        switch self {
        case .medium: "アイコンと名前"
        case .small: "アイコンのみ"
        }
    }

    /// 横並びの区切り線の行のラベル。前からあるアイコンと名前の横並びは「横並び」のままにし、アイコンだけのときに大きさを添える。
    public var rowTitle: String {
        switch self {
        case .medium: "横並び"
        case .small: "横並び（アイコンのみ）"
        }
    }

    /// 区切り線の行のメニューで、選択肢に添える横に並ぶ項目の数。
    /// iOSでは、SwiftUIの`Text`に数を埋めて出していて、`Text`がデバイスの数字の書き方で書いていたため、同じにする。
    public var capacityTitle: String {
        "\(capacity.formatted())個まで"
    }
}
