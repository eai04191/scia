#if DEBUG
import Foundation
import SciaCore

/// デバッグメニューと同じ操作を、`xcrun simctl openurl '<端末>' 'scia-debug://dummy/images'`のようにURLで呼ぶ。
/// agentがメニューを開いてタップせずに、コマンドで確認の準備をするため。
enum DebugURL: Equatable {
    /// いつものビルドは`scia-debug`、撮影用のビルドは`scia-promo-debug`。project.ymlの`SCIA_DEBUG_URL_SCHEME`を、Info.plistを通して読む。
    static let scheme: String = {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "SciaDebugURLScheme") as? String else {
            preconditionFailure("Info.plistにSciaDebugURLSchemeがない")
        }
        return scheme
    }()

    /// `scia-debug://dummy/<DebugDummyPost.rawValue>`
    case dummy(DebugDummyPost)
    /// `scia-debug://scenario/<イベント>`。撮影モード（`ScenarioMode`）のシナリオのイベントを、ストリーミングで流す。
    case scenario(String)
    /// `scia-debug://unauthorized`。以後のREST APIに401を返させ、トークンが無効になった状態にする。
    case unauthorized
    /// `scia-debug://dummy-session`で、通信しないダミーのデータでホームと通知の画面に入る（`DummyServer`）。ログイン画面でも、ログイン済みでも受け付ける。
    case dummySession
    /// `scia-debug://unreadable`。以後のホームと通知の応答の一部を読めない形に壊し、読み込み直す。
    case unreadable
    /// `scia-debug://status/<ステータスコード>`。以後のREST APIにそのステータスのHTMLのエラーページを返させ、読み込み直す。
    /// `?retry-after=<秒>`を付けると、`Retry-After`ヘッダーも返す。`?target=<経路>`で、REST API（`api`、省略時）のほかの経路にも返させる（`DebugFaults.Target`）。
    /// `scia-debug://status/ok`で戻す。
    case status(Int, retryAfter: Int?, target: DebugFaults.Target)
    case statusCleared
    /// `scia-debug://regenerating/on`で、以後のホームの応答を206（サーバーがホームを作り直している最中）にする。`scia-debug://regenerating/off`で戻す。
    case regenerating(Bool)
    /// `scia-debug://unsupported/<OptionalFeature.rawValue>`。以後その機能のAPIに404のHTMLを返させ、このサーバーにはない機能にする。
    case unsupported(OptionalFeature)
    /// `scia-debug://streaming/offline`で今のストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す。
    case streaming(isOnline: Bool)
    /// `scia-debug://download/slow`で、以後の共有や保存のためのダウンロードを、進み具合を少しずつ進めながら10秒遅らせる。
    /// `?seconds=<秒>`で遅らせる時間を変える。`scia-debug://download/normal`で戻す。
    case slowDownload(seconds: Double?)
    /// `scia-debug://menu-icons/slow`で、以後の投稿のメニューで、まだ読んでいないユーザーのアイコンを3秒遅らせてから読む。
    /// `?seconds=<秒>`で遅らせる時間を変える。`scia-debug://menu-icons/normal`で戻す。
    case slowMenuIcons(seconds: Double?)
    /// `scia-debug://lookup/slow`で、以後のプロフィールを開く操作と、メンションとハンドルのコピーで、相手を探すのを3秒遅らせる。
    /// `?seconds=<秒>`で遅らせる時間を変える。`scia-debug://lookup/normal`で戻す。
    case slowLookups(seconds: Double?)
    /// `scia-debug://notice/progress`で、出たままの「処理中」のチップを、進み具合を少しずつ進めながら60秒出す。`?seconds=<秒>`で長さを、`?title=<文言>`で文言を変える。
    /// アプリ全体のアプリ内通知として出すため、画面を移る途中や引っぱる途中のチップの列の動きを、ダウンロードを用意せずに確かめられる。
    case progressNotice(seconds: Double, title: String?)
    /// `scia-debug://notice/transient?title=<文言>`で、数秒で消えるチップを出す。`&seconds=<秒>`で消えるまでの長さを変える。
    /// 2行に折り返す長い文言の出入りや差し替えを、その文言になる失敗を起こさずに確かめるため。
    case transientNotice(title: String, seconds: Double?)
    /// `scia-debug://media-limits?image-size=<バイト>&image-matrix=<画素>&video-size=<バイト>&video-matrix=<画素>&video-frame-rate=<fps>`。
    /// 投稿欄が使うサーバーのメディアの上限を、指定した項目だけ差し替える。次に投稿欄で書き始めたときから効く。`scia-debug://media-limits/server`で戻す。
    case mediaLimits(MediaLimits?)
    /// `scia-debug://catalog`で部品のカタログを開く。`scia-debug://catalog/<CatalogComponent.rawValue>`なら、その部品の状態を並べた画面まで開く。
    case catalog(CatalogComponent?)
    /// `scia-debug://dump`。画面にある要素の名前と枠を、アプリのDocuments/AgentDump/screen.txtに書き出す。
    /// agentがスクリーンショットを読まずに、タップする座標や今の画面を文字で知るため。
    case dump
    /// `scia-debug://storage-probe`。ストレージの画面が測る置き場所を、読めるかを含めて、アプリのDocuments/AgentDump/storage.txtに書き出す（`StorageProbe`）。
    case storageProbe
    /// `scia-debug://browser?url=<URL>`。アプリ内のSafariでURLを開く。実機でアプリ内のSafariのデータを溜めるため。
    case browser(URL)
    /// `scia-debug://reset`。重ねた画面をすべて閉じ、どのタブも最初の画面に戻して、ホームのタブを選ぶ。
    case reset
    /// `scia-debug://settings`。設定を開く。
    case settings
    /// `scia-debug://tuning`。チューニングパネルを開く。
    case tuning
    /// `scia-debug://tab/<home|local|federated|notifications|bookmarks|favourites>`。タブを切り替える。無効にしている項目では何もしない。
    case tab(Tab)
    /// `scia-debug://viewer?index=<n>`。選んでいるタブの、画面のいちばん上に見えている添付ファイル付きの投稿を、n番目（0から）の添付ファイルでビューアに開く。
    /// サムネイルをタップしたのと同じ経路で開く。
    case viewer(index: Int)
    /// `scia-debug://arrivals/hold`で、以後に届いた新着を一覧に挿入せずに溜める。`scia-debug://arrivals/release`で、溜まった新着をまとめて挿入する。
    /// ストリーミングはつないだままなので、切断の知らせやポーリングで一覧が動かない。
    case holdArrivals(Bool)
    /// `scia-debug://autoscroll?distance=<pt>&speed=<pt/秒>`。選んでいるタブの一覧を、決まった速さで決まった距離だけ動かす。distanceが負なら上へ戻す。
    /// 指で操作できない検証用の実機で、スクロールの重さ（hitch）を同じ条件で測るため。慣性のない一定の速さで動かすので、指のスクロールとは動きが違う。
    case autoScroll(distance: CGFloat, speed: CGFloat)
    /// `scia-debug://inject/<home|local|federated|notifications>?file=<ファイル名>`。アプリのDocuments/DebugInjectに置いたJSONを読み、ストリーミングの新着と同じ経路で一覧に流す。
    /// ホーム、ローカル、連合は`Status`の配列、通知は`Notification`の配列で、APIの応答と同じ形で書く。実データにない投稿や通知の見え方を、ログインした端末のまま確かめるため。
    case inject(Tab, file: String)
    /// `scia-debug://compose?text=<本文>&media=<枚数>`。インライン投稿欄で書き始め、本文を渡した文に置き換え、番号を描いた色違いの画像を添付に足す。
    /// どちらも省ける。シミュレーターのクリップボードが使えないときにも、URLを含む本文などを打たずに用意し、ピッカーを操作せずに添付を用意するため。
    /// 本文は打ったときと同じ経路で置き換えるので、末尾の語の補完も出す。画像はペーストと同じ経路で足すので、サーバーに送る。
    /// 撮影モードでは、番号を描いた画像の代わりに、シナリオの写真（`ScenarioScript.draftImages`）を足す。
    case compose(text: String?, mediaCount: Int)
    /// `scia-debug://compose/close`。キーボードを閉じて、投稿欄を書いていないときのカプセルに戻す。下書きは残す。
    case composeClose
    /// `scia-debug://profile-edit?note=<自己紹介>&field=<補足情報の内容>`。自分のプロフィールの編集を開く。`note`を渡すと、読み込んだあとに自己紹介をその文に置き換えて、
    /// 末尾にキーボードを出す。`field`を渡すと、その内容の補足情報を足して、内容の欄の末尾にキーボードを出す。どちらも、打ったときと同じく末尾の語の補完を出す。
    /// シミュレーターの日本語のキーボードでは半角の`:`や`@`を打てないため、補完を確かめるときに語の頭を用意する。
    case profileEdit(note: String?, field: String?)
    /// `scia-debug://sheet-keyboard`。低い段のシートの中で入力欄にキーボードを出したときの動きを確かめる試作を開く（`SheetKeyboardExperiment`）。
    case sheetKeyboard
    /// `scia-debug://ticker-loop/on`で、ステータスバーの通知を、出る、出ている、消えるを繰り返して出し続ける。`scia-debug://ticker-loop/off`で止める。
    case statusBarTickerLoop(Bool)

    /// `scia-debug://lists/create?title=<名前>`でリストを作り、`scia-debug://lists/delete?id=<ID>`で消して、リストを読み直す。
    /// リストの作成と管理の画面がまだないため、リストのタブを実物で確かめるのに使う。サーバーのリストを書き換える。
    case createList(title: String)
    case deleteList(id: String)
    /// `scia-debug://tags/follow?name=<名前>`でハッシュタグをフォローし、`scia-debug://tags/unfollow?name=<名前>`でやめて、フォローしているハッシュタグを読み直す。
    /// ハッシュタグをフォローする操作がまだないため、ハッシュタグのタブを実物で確かめるのに使う。サーバーのフォローを書き換える。
    case followTag(name: String)
    case unfollowTag(name: String)

    enum Tab: String {
        case home
        case local
        case federated
        case notifications
        case bookmarks
        case favourites
        case scheduled
    }

    /// 引数を持たないURL。`host`か`host/path`で引く。
    private static let fixed: [String: DebugURL] = [
        "dummy-session": .dummySession,
        "unauthorized": .unauthorized,
        "unreadable": .unreadable,
        "status/ok": .statusCleared,
        "regenerating/on": .regenerating(true),
        "regenerating/off": .regenerating(false),
        "streaming/offline": .streaming(isOnline: false),
        "streaming/online": .streaming(isOnline: true),
        "download/normal": .slowDownload(seconds: nil),
        "menu-icons/normal": .slowMenuIcons(seconds: nil),
        "lookup/normal": .slowLookups(seconds: nil),
        "media-limits/server": .mediaLimits(nil),
        "catalog": .catalog(nil),
        "dump": .dump,
        "storage-probe": .storageProbe,
        "reset": .reset,
        "compose/close": .composeClose,
        "settings": .settings,
        "tuning": .tuning,
        "sheet-keyboard": .sheetKeyboard,
        "ticker-loop/on": .statusBarTickerLoop(true),
        "ticker-loop/off": .statusBarTickerLoop(false),
        "arrivals/hold": .holdArrivals(true),
        "arrivals/release": .holdArrivals(false),
    ]

    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let fixed = Self.fixed[path.isEmpty ? host : "\(host)/\(path)"] {
            self = fixed
            return
        }
        let last = url.lastPathComponent
        let parsed: DebugURL? = switch host {
        case "dummy": DebugDummyPost(rawValue: last).map { .dummy($0) }
        case "scenario": .scenario(last)
        case "unsupported": OptionalFeature(rawValue: last).map { .unsupported($0) }
        case "tab": Tab(rawValue: last).map { .tab($0) }
        case "catalog": CatalogComponent(rawValue: last).map { .catalog($0) }
        case "status": Self.status(url)
        case "download": Self.slowDownload(url)
        case "menu-icons": Self.slowMenuIcons(url)
        case "lookup": Self.slowLookups(url)
        case "notice": Self.notice(url)
        case "media-limits": Self.mediaLimits(url)
        case "viewer": Self.viewer(url)
        case "autoscroll": Self.autoScroll(url)
        case "inject": Self.inject(url)
        case "lists": Self.lists(url)
        case "tags": Self.tags(url)
        case "compose": Self.compose(url)
        case "browser": Self.query("url", in: url).flatMap(URL.init(string:)).flatMap { LinkBrowser.inApp.browser(for: $0) == .inApp ? .browser($0) : nil }
        case "profile-edit": .profileEdit(note: Self.query("note", in: url), field: Self.query("field", in: url))
        default: nil
        }
        guard let parsed else { return nil }
        self = parsed
    }

    private static func query(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func status(_ url: URL) -> DebugURL? {
        guard let statusCode = Int(url.lastPathComponent), (100..<600).contains(statusCode) else { return nil }
        let target: DebugFaults.Target
        if let name = query("target", in: url) {
            guard let named = DebugFaults.Target(rawValue: name) else { return nil }
            target = named
        } else {
            target = .api
        }
        return .status(statusCode, retryAfter: query("retry-after", in: url).flatMap { Int($0) }, target: target)
    }

    private static func lists(_ url: URL) -> DebugURL? {
        switch url.lastPathComponent {
        case "create": query("title", in: url).flatMap { $0.isEmpty ? nil : .createList(title: $0) }
        case "delete": query("id", in: url).flatMap { $0.isEmpty ? nil : .deleteList(id: $0) }
        default: nil
        }
    }

    private static func tags(_ url: URL) -> DebugURL? {
        guard let name = query("name", in: url), !name.isEmpty else { return nil }
        switch url.lastPathComponent {
        case "follow": return .followTag(name: name)
        case "unfollow": return .unfollowTag(name: name)
        default: return nil
        }
    }

    private static func slowDownload(_ url: URL) -> DebugURL? {
        guard url.lastPathComponent == "slow" else { return nil }
        return .slowDownload(seconds: query("seconds", in: url).flatMap { Double($0) } ?? 10)
    }

    private static func slowMenuIcons(_ url: URL) -> DebugURL? {
        guard url.lastPathComponent == "slow" else { return nil }
        return .slowMenuIcons(seconds: query("seconds", in: url).flatMap { Double($0) } ?? 3)
    }

    private static func slowLookups(_ url: URL) -> DebugURL? {
        guard url.lastPathComponent == "slow" else { return nil }
        return .slowLookups(seconds: query("seconds", in: url).flatMap { Double($0) } ?? 3)
    }

    private static func notice(_ url: URL) -> DebugURL? {
        let seconds = query("seconds", in: url).flatMap { Double($0) }
        // 正の有限値だけを受け付ける。NaNや無限大はDurationにできず落ちるため。
        if let seconds, !(seconds.isFinite && seconds > 0) { return nil }
        let title = query("title", in: url)
        switch url.lastPathComponent {
        case "progress": return .progressNotice(seconds: seconds ?? 60, title: title)
        case "transient": return title.map { .transientNotice(title: $0, seconds: seconds) }
        default: return nil
        }
    }

    private static func mediaLimits(_ url: URL) -> DebugURL? {
        func value(_ name: String) -> Int? { query(name, in: url).flatMap { Int($0) } }
        return .mediaLimits(MediaLimits(
            imageSizeLimit: value("image-size"),
            imageMatrixLimit: value("image-matrix"),
            videoSizeLimit: value("video-size"),
            videoMatrixLimit: value("video-matrix"),
            videoFrameRateLimit: value("video-frame-rate")
        ))
    }

    private static func inject(_ url: URL) -> DebugURL? {
        guard let tab = Tab(rawValue: url.lastPathComponent), let file = query("file", in: url), !file.isEmpty else { return nil }
        return .inject(tab, file: file)
    }

    private static func compose(_ url: URL) -> DebugURL? {
        let text = query("text", in: url)
        guard let mediaCount = Int(query("media", in: url) ?? "0"), mediaCount >= 0, text != nil || mediaCount > 0 else { return nil }
        return .compose(text: text, mediaCount: mediaCount)
    }

    private static func autoScroll(_ url: URL) -> DebugURL? {
        guard let distance = query("distance", in: url).flatMap(Double.init),
              let speed = Double(query("speed", in: url) ?? "2000"), speed > 0
        else { return nil }
        return .autoScroll(distance: distance, speed: speed)
    }

    private static func viewer(_ url: URL) -> DebugURL? {
        guard let index = Int(query("index", in: url) ?? "0"), index >= 0 else { return nil }
        return .viewer(index: index)
    }
}
#endif
