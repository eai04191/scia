public import Foundation

/// アプリの外から直接開ける画面。`scia://<host>/<path>?<query>`のURLで表し、アプリのURLと、これから足すショートカットは、この型を通して画面を開く。
/// 画面を足したら、ここにも足して、外から開けるようにする（AGENTS.mdの「シミュレーター」）。
public enum AppDestination: Equatable, Sendable {
    /// `tab/<home|local|federated|notifications|search|bookmarks|favourites|scheduled>`。最初からあるタブを選ぶ。
    case tab(TabItem)
    /// `tab/list?id=<リストのID>`、`tab/hashtag?name=<名前>`、`tab/profile?acct=<ハンドル>`、`tab/account-hashtag?acct=<ハンドル>&name=<名前>`。足したタブを選ぶ。
    case userTab(UserTab)
    /// `settings`で設定を、`settings/<SettingsPage.rawValue>`で設定の一覧から入るその画面まで重ねて開く。
    case settings(SettingsPage?)
    /// `settings/appearance/<分類のID>`。「投稿の見た目」の、その分類（`AppearanceCatalog.groups`）の画面まで重ねて開く。
    case appearanceGroup(AppearanceGroup.ID)
    /// `profile/<user@domain>`。ローカルのアカウントは`<user>`だけでもよい。ホームのタブにプロフィールを開く。
    case profile(acct: String)
    /// `my-profile`。選んでいるタブに、自分のプロフィールを開く。
    case myProfile
    /// `profile-edit`。自分のプロフィールの編集を開く。
    case profileEdit
    /// `thread?id=<投稿のID>`。選んでいるタブに、その投稿のスレッドを開く。
    case thread(statusID: String)
    /// `edit-history?id=<投稿のID>`。その投稿の編集履歴を開く。
    case editHistory(statusID: String)
    /// `api-response?id=<投稿のID>`。その投稿をサーバーから読み直し、APIの応答のJSONを開く。
    case apiResponse(statusID: String)
    /// `accounts/<followers|following>`で自分の、`?id=<アカウントのID>`でその人のフォロワーかフォローの一覧を開く。
    /// `accounts/<favourited|reblogged>?id=<投稿のID>`で、その投稿をお気に入りした人、ブーストした人の一覧を開く。
    case accounts(AccountList)
    /// `hashtag?name=<名前>`。選んでいるタブに、そのハッシュタグの投稿の一覧を開く。
    case hashtag(name: String)
    /// `account-hashtag?acct=<ハンドル>&name=<名前>`。選んでいるタブに、その人のそのハッシュタグの投稿の一覧を開く。
    case accountHashtag(acct: String, name: String)
    /// `search?q=<語>`。検索のタブに語を入れて確定する。`q`がなければ、検索のタブを開くだけにする。検索を無効にしていれば、選んでいるタブに検索の画面を開く。
    case search(query: String?)
    /// `scheduled`。予約した投稿の一覧を開く。タブに並べていればそのタブを、無効にしていれば手前に重ねて開く。
    case scheduled
    /// `operation-status`。「操作の状況」の一覧を開く。
    case operationStatus
    /// `notification-requests`。通知のタブに、保留中の通知の一覧を開く。
    case notificationRequests
    /// `notification-request?id=<保留中の通知のID>`。通知のタブに、保留中の通知の一覧と、その人からの通知を重ねて開く。
    case notificationRequest(id: String)
    /// `notification-policy`。通知のフィルタリングの設定を開く。
    case notificationPolicy
    /// `announcements`。サーバーのお知らせの一覧を開く。
    case announcements
    /// `in-app-browser-height`。重ねた画面を閉じてホームのタブを出し、その上にアプリ内のSafariの高さを選ぶシートを出す。
    /// `?return=<SettingsPage.rawValue>`で、シートを閉じたときにその設定の画面を開き直す。
    case inAppBrowserHeight(returningTo: SettingsPage?)
    /// `note?acct=<ハンドル>`。その人のプロフィールに書く、自分にしか見えないメモの画面を開く。
    case note(acct: String)
    /// `report?acct=<ハンドル>`。その人を通報する画面を開く。送らない限りサーバーに届かない。
    case report(acct: String)
    /// `compose/<画面>`。投稿欄で書き始め、投稿欄から開く画面を開く。
    case compose(ComposeScreen)

    /// 足したタブ。並びの項目は同じサーバーの人をサーバー名のないハンドルで持つため、比べるときにログイン中のアカウントでそろえる。
    public enum UserTab: Equatable, Sendable {
        case list(id: String)
        case hashtag(name: String)
        case profile(acct: String)
        case accountHashtag(acct: String, name: String)

        /// - Parameter credential: ログイン中のアカウント。同じサーバーの人のハンドルにサーバー名を補う。
        public func matches(_ item: TabItem, credential: Credential) -> Bool {
            func sameAcct(_ lhs: String, _ rhs: String) -> Bool {
                credential.handle(ofAcct: String(lhs.trimmingPrefix("@"))).lowercased() == credential.handle(ofAcct: String(rhs.trimmingPrefix("@"))).lowercased()
            }
            func sameTag(_ lhs: String, _ rhs: String) -> Bool {
                Hashtag.normalizedName(lhs) == Hashtag.normalizedName(rhs)
            }
            return switch (self, item) {
            case (.list(let id), .list(let itemID, _)): id == itemID
            case (.hashtag(let name), .hashtag(let itemName)): sameTag(name, itemName)
            case (.profile(let acct), .profile(_, let itemAcct, _)): sameAcct(acct, itemAcct)
            case (.accountHashtag(let acct, let name), .accountHashtag(_, let itemAcct, let itemName, _)): sameAcct(acct, itemAcct) && sameTag(name, itemName)
            default: false
            }
        }
    }

    public enum AccountList: Equatable, Sendable {
        /// nilなら自分。
        case followers(accountID: String?)
        case following(accountID: String?)
        case favourited(statusID: String)
        case reblogged(statusID: String)
    }

    public enum ComposeScreen: Equatable, Sendable {
        /// `compose/tools`。投稿欄のボタンの並び。
        case tools
        /// `compose/language`。投稿の言語。
        case language
        /// `compose/schedule`。予約の日時。予約していなければ予約を始める。
        case schedule
        /// `compose/emoji`。カスタム絵文字のパレット。
        case emoji
        /// `compose/media-picker`。メディアを選ぶシート。
        case mediaPicker
        /// `compose/attachment?index=<n>`。n番目（0から）の添付のビューア。
        case attachment(index: Int)
        /// `compose/alt-text?index=<n>`。n番目の添付のビューアで、代替テキストを書き始める。
        case altText(index: Int)
        /// `compose/crop?index=<n>`。n番目の添付の画像を切り抜く画面。
        case crop(index: Int)
    }

    /// タブを選ぶか、タブに積んで見せる行き先か。上に重ねた画面があると見えず、積むのもやめるので、重ねた画面を閉じてから開く。
    /// 手前に重ねる行き先は、下の画面を残して重ねる。ビューアのメニューから開いた設定を閉じると、ビューアに戻るため。
    /// 予約投稿は、タブを無効にしていれば手前に重ねるが、タブに並べていればタブを見せるので、こちらに入れる。
    public var showsTab: Bool {
        switch self {
        case .tab, .userTab, .profile, .myProfile, .thread, .editHistory, .apiResponse, .accounts, .hashtag, .accountHashtag, .search, .scheduled,
             .notificationRequests, .notificationRequest:
            true
        case .settings, .appearanceGroup, .profileEdit, .operationStatus, .notificationPolicy, .announcements, .inAppBrowserHeight, .note, .report, .compose:
            false
        }
    }

    /// ログに書く説明。ハンドルやID、名前は、誰の何を開いたかが分かるので書かず、画面の種類だけにする（docs/logging.md）。
    public var logDescription: String {
        switch self {
        case .tab(let item): "tab \(item.rawValue)"
        case .userTab: "user tab"
        case .settings(let page): "settings \(page?.rawValue ?? "")"
        case .appearanceGroup(let id): "settings appearance/\(id)"
        case .profile: "profile"
        case .myProfile: "my profile"
        case .profileEdit: "profile edit"
        case .thread: "thread"
        case .editHistory: "edit history"
        case .apiResponse: "api response"
        case .accounts: "accounts"
        case .hashtag: "hashtag"
        case .accountHashtag: "account hashtag"
        case .search: "search"
        case .scheduled: "scheduled"
        case .operationStatus: "operation status"
        case .notificationRequests: "notification requests"
        case .notificationRequest: "notification request"
        case .notificationPolicy: "notification policy"
        case .announcements: "announcements"
        case .inAppBrowserHeight: "in-app browser height"
        case .note: "note"
        case .report: "report"
        case .compose: "compose screen"
        }
    }

    /// スキームを問わず、ホストとパスとクエリで読む。
    public init?(_ url: URL) {
        guard let host = url.host() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        func index() -> Int? {
            guard let index = Int(query("index") ?? "0"), index >= 0 else { return nil }
            return index
        }
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parsed: AppDestination? = switch (host, path) {
        case ("tab", "list"): query("id").map { .userTab(.list(id: $0)) }
        case ("tab", "hashtag"): query("name").map { .userTab(.hashtag(name: $0)) }
        case ("tab", "profile"): query("acct").map { .userTab(.profile(acct: $0)) }
        case ("tab", "account-hashtag"): query("acct").flatMap { acct in query("name").map { .userTab(.accountHashtag(acct: acct, name: $0)) } }
        case ("tab", _): Self.fixedTabs.first { $0.rawValue == path }.map { .tab($0) }
        case ("settings", ""): .settings(nil)
        case ("settings", _) where path.hasPrefix(Self.appearanceGroupPrefix):
            Self.appearanceGroup(id: String(path.dropFirst(Self.appearanceGroupPrefix.count)))
        case ("settings", _): SettingsPage(rawValue: path).map { .settings($0) }
        case ("profile", _):
            // `@user@domain`の形で書かれていても読めるよう、先頭の@を外す。
            path.contains("/") ? nil : (path.isEmpty ? nil : .profile(acct: String(path.trimmingPrefix("@"))))
        case ("my-profile", ""): .myProfile
        case ("profile-edit", ""): .profileEdit
        case ("thread", ""): query("id").map { .thread(statusID: $0) }
        case ("edit-history", ""): query("id").map { .editHistory(statusID: $0) }
        case ("api-response", ""): query("id").map { .apiResponse(statusID: $0) }
        case ("accounts", "followers"): .accounts(.followers(accountID: query("id")))
        case ("accounts", "following"): .accounts(.following(accountID: query("id")))
        case ("accounts", "favourited"): query("id").map { .accounts(.favourited(statusID: $0)) }
        case ("accounts", "reblogged"): query("id").map { .accounts(.reblogged(statusID: $0)) }
        case ("hashtag", ""): query("name").map { .hashtag(name: $0) }
        case ("account-hashtag", ""): query("acct").flatMap { acct in query("name").map { .accountHashtag(acct: acct, name: $0) } }
        case ("search", ""): .search(query: query("q"))
        case ("scheduled", ""): .scheduled
        case ("operation-status", ""): .operationStatus
        case ("notification-requests", ""): .notificationRequests
        case ("notification-request", ""): query("id").map { .notificationRequest(id: $0) }
        case ("notification-policy", ""): .notificationPolicy
        case ("announcements", ""): .announcements
        case ("in-app-browser-height", ""):
            if let page = query("return") {
                SettingsPage(rawValue: page).map { .inAppBrowserHeight(returningTo: $0) }
            } else {
                .inAppBrowserHeight(returningTo: nil)
            }
        case ("note", ""): query("acct").map { .note(acct: $0) }
        case ("report", ""): query("acct").map { .report(acct: $0) }
        case ("compose", "tools"): .compose(.tools)
        case ("compose", "language"): .compose(.language)
        case ("compose", "schedule"): .compose(.schedule)
        case ("compose", "emoji"): .compose(.emoji)
        case ("compose", "media-picker"): .compose(.mediaPicker)
        case ("compose", "attachment"): index().map { .compose(.attachment(index: $0)) }
        case ("compose", "alt-text"): index().map { .compose(.altText(index: $0)) }
        case ("compose", "crop"): index().map { .compose(.crop(index: $0)) }
        default: nil
        }
        guard let parsed else { return nil }
        self = parsed
    }

    /// この画面を開くURL。`init?(_:)`で読み戻すと同じ画面になる。開く先を足したときに、URLの形を決め忘れないよう、すべての項目を扱う形で書く。
    /// 空の名前やID、負の番号のように、URLにしても読み戻すと別の画面になるか読めない値では、nilを返す。
    public func url(scheme: String) -> URL? {
        let (host, path, query): (String, String?, [(String, String)]) = switch self {
        case .tab(let item): ("tab", item.rawValue, [])
        case .userTab(.list(let id)): ("tab", "list", [("id", id)])
        case .userTab(.hashtag(let name)): ("tab", "hashtag", [("name", name)])
        case .userTab(.profile(let acct)): ("tab", "profile", [("acct", acct)])
        case .userTab(.accountHashtag(let acct, let name)): ("tab", "account-hashtag", [("acct", acct), ("name", name)])
        case .settings(let page): ("settings", page?.rawValue, [])
        case .appearanceGroup(let id): ("settings", Self.appearanceGroupPrefix + id, [])
        case .profile(let acct): ("profile", acct, [])
        case .myProfile: ("my-profile", nil, [])
        case .profileEdit: ("profile-edit", nil, [])
        case .thread(let statusID): ("thread", nil, [("id", statusID)])
        case .editHistory(let statusID): ("edit-history", nil, [("id", statusID)])
        case .apiResponse(let statusID): ("api-response", nil, [("id", statusID)])
        case .accounts(.followers(let accountID)): ("accounts", "followers", accountID.map { [("id", $0)] } ?? [])
        case .accounts(.following(let accountID)): ("accounts", "following", accountID.map { [("id", $0)] } ?? [])
        case .accounts(.favourited(let statusID)): ("accounts", "favourited", [("id", statusID)])
        case .accounts(.reblogged(let statusID)): ("accounts", "reblogged", [("id", statusID)])
        case .hashtag(let name): ("hashtag", nil, [("name", name)])
        case .accountHashtag(let acct, let name): ("account-hashtag", nil, [("acct", acct), ("name", name)])
        case .search(let query): ("search", nil, query.map { [("q", $0)] } ?? [])
        case .scheduled: ("scheduled", nil, [])
        case .operationStatus: ("operation-status", nil, [])
        case .notificationRequests: ("notification-requests", nil, [])
        case .notificationRequest(let id): ("notification-request", nil, [("id", id)])
        case .notificationPolicy: ("notification-policy", nil, [])
        case .announcements: ("announcements", nil, [])
        case .inAppBrowserHeight(let page): ("in-app-browser-height", nil, page.map { [("return", $0.rawValue)] } ?? [])
        case .note(let acct): ("note", nil, [("acct", acct)])
        case .report(let acct): ("report", nil, [("acct", acct)])
        case .compose(.tools): ("compose", "tools", [])
        case .compose(.language): ("compose", "language", [])
        case .compose(.schedule): ("compose", "schedule", [])
        case .compose(.emoji): ("compose", "emoji", [])
        case .compose(.mediaPicker): ("compose", "media-picker", [])
        case .compose(.attachment(let index)): ("compose", "attachment", [("index", String(index))])
        case .compose(.altText(let index)): ("compose", "alt-text", [("index", String(index))])
        case .compose(.crop(let index)): ("compose", "crop", [("index", String(index))])
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path.map { "/\($0)" } ?? ""
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url, AppDestination(url) == self else { return nil }
        return url
    }

    /// 分類の画面のパスの、分類のIDの前。
    private static let appearanceGroupPrefix = "\(SettingsPage.appearance.rawValue)/"

    /// 分類のIDが「投稿の見た目」の分類なら、その画面。
    private static func appearanceGroup(id: String) -> AppDestination? {
        AppearanceCatalog.groups.contains { $0.id == id } ? .appearanceGroup(id) : nil
    }

    /// 最初からあるタブ。足したタブは`userTab`で選ぶ。
    private static let fixedTabs: [TabItem] = [.home, .local, .federated, .notifications, .search, .bookmarks, .favourites, .scheduled]
}

/// 設定の一覧から重ねて開く画面。`rawValue`は、`scia://settings/<rawValue>`でその画面を直接開くときの名前。
public enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    /// 表示の分類。投稿と通知の見た目、動き、ステータスバーの通知を並べる。
    case display
    /// 操作の分類。対象ごとの画面（タップと長押しの操作と、その対象のメニューの並び）、リンクを開く場所、ブーストの公開範囲を並べる。
    case interaction
    /// 投稿欄の分類。
    case compose
    /// メディアの分類。HDRの明るさ、サムネイルの画質、代替テキストを並べる。
    case media
    /// 情報。アプリのビルドと、接続の状態、ライセンス、謝辞を並べる。
    case about
    /// アプリのアイコン。
    case appIcon = "app-icon"
    case appearance
    case notificationAppearance = "notification-appearance"
    case tabs
    case statusActions = "status-actions"
    case notificationActions = "notification-actions"
    case userActions = "user-actions"
    case linkActions = "link-actions"
    case externalPostActions = "external-post-actions"
    case hashtagActions = "hashtag-actions"
    case mediaActions = "media-actions"
    case statusMenu = "status-menu"
    case userMenu = "user-menu"
    case linkMenu = "link-menu"
    case externalPostMenu = "external-post-menu"
    case profileTextMenu = "profile-text-menu"
    case hashtagMenu = "hashtag-menu"
    case mediaMenu = "media-menu"
    case composeTools = "compose-tools"
    case connection
    case storage
    /// ストレージの、メディアのキャッシュの表示済みの段。
    case viewedMediaCache = "storage-viewed"
    /// ストレージの、メディアのキャッシュの先読みの段。
    case prefetchedMediaCache = "storage-prefetched"
    case licenses
    case acknowledgments

    /// 設定の一覧からこの画面までに重ねる画面。
    public var path: [SettingsPage] {
        switch self {
        case .appearance, .notificationAppearance: [.display, self]
        case .statusActions, .notificationActions, .userActions, .linkActions, .externalPostActions, .hashtagActions, .mediaActions,
             .profileTextMenu:
            [.interaction, self]
        case .statusMenu: [.interaction, .statusActions, self]
        case .userMenu: [.interaction, .userActions, self]
        case .linkMenu: [.interaction, .linkActions, self]
        case .externalPostMenu: [.interaction, .externalPostActions, self]
        case .hashtagMenu: [.interaction, .hashtagActions, self]
        case .mediaMenu: [.interaction, .mediaActions, self]
        case .composeTools: [.compose, self]
        case .connection, .licenses, .acknowledgments: [.about, self]
        case .viewedMediaCache, .prefetchedMediaCache: [.storage, self]
        case .display, .interaction, .compose, .media, .about, .appIcon, .tabs, .storage: [self]
        }
    }
}
