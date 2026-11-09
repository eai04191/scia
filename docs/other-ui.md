# 別のUIからSciaCoreを使う

SciaCoreだけで、iOSのアプリ（`App/Sources`）とは別のUI（AppKitのMac版など）を作るときの入口。ほかの`docs/`はiOSの画面ごとの決まりで書いてあるので、何をSciaCoreの部品に任せ、何をUIで書くかをここから引く。ここに挙げた部品の決まりは、UIで書き直さない。書き直すと、同じSciaCoreでも読み込みの間合いや既読の位置がUIによって変わる。

## アプリで1つ作るもの

- `TuningStore`: Releaseでも値を読むので、どのUIも作る。パネルを持たないなら`TuningStore(defaults: nil)`で既定値を使う
- `AppSettings`: 設定。サムネイルの回線の条件や、リンクを開く先もここから読む
- `HTTPClient`: APIの外の通信の口。決まりは[network.md](network.md)
- `NetworkConditionsMonitor`: 回線の見張り。サムネイルの条件（`thumbnailPolicy(settings:tuning:)`）と、電波が戻った回数（`recoveryCount`）を出す
- `ImageStores`: アイコンと添付ファイルの画像のストア。置き場所、読み方、読み直しの間隔まで組んである。UIは画像の型の作り方（`PlatformImageMaker`）だけを渡す
- `CrashMark`と`PostQuarantine`、`PostCrashReport`: クラッシュした投稿の隔離と、開発者に送る文章（[crash-quarantine.md](crash-quarantine.md)）。行の処理の前に印を付け、隠すのと送る画面はUIで書く
- `AccountRegistry`と`KeychainCredentialStore(service:)`: ログインしたアカウント。サービス名はUIで決める

## ログイン

- `LoginModel`と`OAuthClient`。`OAuthClient.Configuration`には戻る先のURLだけを渡す。アプリの名前と求めるスコープはSciaCoreが決める
- 認可の画面を出すのはUI（`LoginModel.login(authenticate:)`に渡す）

## アカウント1つ分

- `AccountSession`を作り、閉じるまで持つ。`observeRecoveries(networkRecoveryCount:)`に`NetworkConditionsMonitor.recoveryCount`を渡す
- 一覧のモデルは`init(…session:…)`で作る。`session`を受け取らない一覧（`ThreadModel`、`SearchModel`、`AccountNotificationsModel`、UIが持つ一覧）は、`session.statuses.register(_:)`で登録する。登録した一覧は、削除、編集、お気に入りなどで変わった投稿を受け取る
- アカウントの設定（`onPreferencesLoad`）は、注意書きを最初から開くか（`ServerPreferences.expandsSpoilers`を`SpoilerExpansion`へ）に使う
- `backgroundTime`の引数と`enterBackground()`、`enterForeground()`は、OSがバックグラウンドでアプリを止めるUIだけが使う

## タイムライン

- 画面は`TimelineDisplay`に従う。モデルからの命令（位置を保つ行、上端に置く行、消える行を動かすか）を守るのがUIの役目
- どの行を既読として報告し、どんな間は報告しないかは`ReadVisibility`
- 末尾の何行手前で続きを読み、どのギャップをどちらの端から読むかは`TimelineLoadTrigger`。結果を`approachEnd()`と`approachGap(_:from:)`に渡す
- 引用元の囲みは、`session.statuses.quoteSources`を当てて出し、`onQuoteSourcesChange`で描き直す
- サムネイルにどの画像を読むかは`MediaThumbnailSelection`に、`NetworkConditionsMonitor.thumbnailPolicy(settings:tuning:)`の条件を渡して決める

## 投稿

- 投稿欄は`ComposeModel`。`AccountSession.applyComposeDefaults(to:)`が済むまで`canPost`はfalseのまま
- 送れた結果（`onSubmitted`）は`session.statuses.reflect(_:usingTagsIn:)`に渡す。どの一覧へ配るかはそこで決まる
- 編集を始める前の確認は`Confirmation.editing`、後から選んだ投稿の読み込みだけを使うのは`LatestLookup`
- 削除は、`Confirmation.deleting`で確かめてから`StatusDeletion.delete(_:onFailure:)`。どの一覧からも除き、投稿欄の編集や書き直しもやめる。ほかのアカウントの投稿を消したら、`ComposeModel.statusWasDeleted(_:accountID:willReset:)`をそのアカウントのIDで呼ぶ

## メニューと確認と失敗

- 何を出すかはSciaCoreが決め、UIは描くだけにする。確認は`Confirmation`、メニューは`MenuNode`（`StatusMenuTree`など）
- 受け持たない項目を外した並びは、`MenuLayout(defaultElements:)`で作る
- 失敗の文言は`ErrorPresentation`（`@_spi(FailureDisplay) import SciaCore`で読む）

## SciaCoreにあるが、iOSの画面の作りに合わせた部品

`MediaBarSwap`、`TextMorphPlan`、`DragToDismiss`、`SpringDriver`、`FrameTicker`、`SpringScroll`は、iOSの画面の重なりや動きに合わせてある。UIKitをimportしないので別のUIでもビルドできるが、同じ画面の作りでなければ使わない。
