# 別のUIからSciaCoreを使う

SciaCoreだけで、iOSのアプリ（`App/Sources`）とは別のUI（AppKitのMac版など）を作るときの入口。ほかの`docs/`はiOSの画面ごとの決まりで書いてあるので、何をSciaCoreの部品に任せ、何をUIで書くかをここから引く。ここに挙げた部品の決まりは、UIで書き直さない。書き直すと、同じSciaCoreでも読み込みの間合いや既読の位置がUIによって変わる。

## 通信を始めるところで、目的を名乗る

- 通信は、始めるところで目的（`RequestPurpose`）を名乗る。名乗らずに送ると、通信の入口が送らずに失敗させる（`UndeclaredRequestPurpose`）。SwiftUIの`.task`や裸の`Task`は名乗らないので、そこから読み込みを始めると、どれも失敗する。決まりは[network.md](network.md)の「通信の目的」にある
- 使う人の操作で始めるなら`Task(.action) { … }`、表示のために読むなら`Task(.display) { … }`、通信しない処理は`Task(.withoutRequests) { … }`と書く。セッションの持ち物で始める処理は、`TaskScope.run(_:_:)`に目的を渡す
- SwiftUIの`.task`は、中を`RequestPurpose.$current.withValue(.action) { … }`で囲む。SciaCoreはSwiftUIをimportしないので、囲んだ`.task(.action) { … }`の入口はUIが持つ（iOSは`App/Sources/RequestPurposeTask.swift`）

## アプリで1つ作るもの

- `TuningStore`: Releaseでも値を読むので、どのUIも作る。パネルを持たないなら`TuningStore(defaults: nil)`で既定値を使う
- `AppSettings`: 設定。サムネイルの回線の条件や、リンクを開く先もここから読む
- `HTTPClient`: APIの外の通信の口。決まりは[network.md](network.md)
- `NetworkConditionsMonitor`: 回線の見張り。サムネイルの条件（`thumbnailPolicy(settings:tuning:)`）と、電波が戻った回数（`recoveryCount`）を出す
- `ImageStores`: アイコン、添付ファイル、カスタム絵文字の画像のストア（`avatars`、`media`、`emojis`）と、サーバーごとのカスタム絵文字のリスト（`customEmojis`）。置き場所、読み方、読み直しの間隔まで組んである。UIは画像の型の作り方（`PlatformImageMaker`）だけを渡す。絵文字の画像のストアは、アカウントごとに作らない
- カスタム絵文字の画像は、`ImageStores`が`emojiImageFiles`（`EmojiImageFiles`）に、端末に残した`api/v1/custom_emojis`の応答に載っている画像（A）とそれ以外（B）を分けて置く。応答が変わったら（`CustomEmojiCaches.onListsChanged`）、`EmojiImageFiles.updateListed(_:)`で分け直し、`EmojiPrefetch`で先読みする。絵文字ピッカーの小さい静止画は`emojiThumbnails`（`EmojiThumbnails`）。決まりは[animated-custom-emoji.md](animated-custom-emoji.md)
- 設定のストレージの「絵文字」の中の行は、`EmojiStorageRow.rows(_:)`で数える
- `CrashMark`と`PostQuarantine`、`PostCrashReport`: クラッシュした投稿の隔離と、開発者に送る文章（[crash-quarantine.md](crash-quarantine.md)）。行の処理の前に印を付け、隠すのと送る画面はUIで書く
- `AccountRegistry`と`KeychainCredentialStore(service:)`: ログインしたアカウント。サービス名はUIで決める
- ログアウトは`AccountLogout.logOut(_:from:defaults:settings:images:)`。アカウントのリストから消し、そのアカウントのために覚えた設定、メディアのキャッシュ、そのサーバーのカスタム絵文字のリストを消す。呼んだあと、そのアカウントのセッションを閉じ、残ったアカウントかログインの画面を出すのはUI。使う人がログアウトを選んだときだけ呼ぶ

## ログイン

- `LoginModel`と`OAuthClient`。`OAuthClient.Configuration`には戻る先のURLだけを渡す。アプリの名前と求めるスコープはSciaCoreが決める
- 認可の画面を出すのはUI（`LoginModel.startLogin(authenticate:)`に渡す）
- サーバーの応答を待つのが長引いたら`offersCancel`がtrueになるので、やめる操作を出して`cancelLogin()`を呼ぶ

## アカウント1つ分

- `AccountSession`を作り、閉じるまで持つ。アカウントを切り替えるときは、前のセッションを`close()`してから、次のアカウントのセッションを作る
- 画面を出すときに`start(networkRecoveryCount:)`を1度呼び、`NetworkConditionsMonitor.recoveryCount`を渡す。やり直しの見張りと、アニメーションの設定を始める。通信はしない
- そのあと`loadServerInfo()`を1度呼び、サーバーの版、投稿欄の既定、サーバーの機能を読む。起動してすぐのタイムラインの読み込みと同時に送ると、サーバーで順番待ちになってタイムラインが遅れるので、最初のタイムラインを読み終えてから呼ぶ（iOSでは`FeedTimelineModel.onInitialLoadFinished`）。`onPreferencesLoad`、`onCapabilitiesLoad`、`onCredentialsInvalid`は、呼ぶ前に置く
- アカウントごとに1つ持つ部品は、セッションが作って持つ。UIでは作らない
  - `accounts`（`AccountCache`）と`relationships`（`RelationshipCache`）: IDからアカウントと関係を引く。IDやハンドルしか持たない行き先（`AppDestination.profile(acct:)`など）は、ここから引く。`accounts`は、セッションのクライアントとストリーミングが受け取ったアカウントを、読み始めた順で一番新しいものにして覚えている。人のアイコンや名前と、プロフィールを開くときに最初に出すアカウントは、ここから取る（[profile.md](profile.md)の「開いたときに出すアカウント」）
  - `diagnostics`（`ConnectionDiagnostics`）: 接続の状態の画面に出す値。ストリーミングの状態とサーバーの版（`diagnostics.serverVersion`）は、セッションが入れる
  - `xPosts`（`XPostStore`）、`polls`（`PollVoting`）、`translations`（`StatusTranslationStore`）: Xの投稿、投票、自動翻訳。設定の変化（Xの投稿の展開、自動翻訳の言語など）は、セッションがストアへ流す。自動翻訳は、訳す部品（`StatusTranslationSetup`）をセッションに渡したUIだけが持つ
  - 届いたものを描き直すのはUI。`xPosts.onChange`、`translations?.onChange`、`onTranslationSettingsChange`で受ける
- ストリーミングの状態の変化は、`streamingHub.onChange`ではなく`onStreamingChange`で受ける。`streamingHub.onChange`は1つしか置けず、セッションが使う
- 一覧のモデルは`init(…session:…)`で作る。`session`を受け取らない一覧（`ThreadModel`、`SearchModel`、`AccountNotificationsModel`、UIが持つ一覧）は、`session.statuses.register(_:)`で登録する。登録した一覧は、削除、編集、お気に入りなどで変わった投稿を受け取る
- アカウントの設定（`onPreferencesLoad`）は、注意書きを最初から開くか（`ServerPreferences.expandsSpoilers`を`SpoilerExpansion`へ）に使う。アニメーションを再生するかは、セッションが設定（`AppSettings`）へ覚えさせる
- `tasks: TaskScope`を受け取るモデル（`ThreadModel`、`SearchModel`、`NotificationRequestsModel`、`AccountNotificationsModel`など）には、`session.tasks.child()`を渡す。`TaskScope`は手放すと閉じるので、画面を閉じたときに`close()`を呼ばなくてよい。モデルを持つものが捨てられれば、始めた処理も止まる
- `backgroundTime`の引数と`enterBackground()`、`enterForeground()`は、OSがバックグラウンドでアプリを止めるUIだけが使う

## タイムライン

- 画面は`TimelineDisplay`に従う。モデルからの命令（位置を保つ行、上端に置く行、消える行を動かすか）を守るのがUIの役目
- どの行を既読として報告し、どんな間は報告しないかは`ReadVisibility`
- 末尾の何行手前で続きを読み、どのギャップをどちらの端から読むかは`TimelineLoadTrigger`。結果を`approachEnd()`と`approachGap(_:from:)`に渡す
- 引用元の囲みは、`session.statuses.quoteSources`を当てて出し、`onQuoteSourcesChange`で描き直す
- サムネイルにどの画像を読むかは`MediaThumbnailSelection`に、`NetworkConditionsMonitor.thumbnailPolicy(settings:tuning:)`の条件を渡して決める

- 一覧のモデルの始め方は、モデルごとに違う
  - `FeedTimelineModel`、`NotificationsModel`: 起動のときに読むなら`start(purpose:)`、開くまで読まないなら、画面に出るたびに`startIfNeeded()`。`startIfNeeded()`は何度呼んでもよい
  - `SavedStatusesModel`: 画面に出るたびに`startIfNeeded()`
  - `ScheduledStatusesModel`: 画面に出るたびに`appear()`、消えたときに`disappear()`
  - `ThreadModel`、`SearchModel`: 画面に積む前に`start()`を1度
  - `NotificationRequestsModel`、`AccountNotificationsModel`: `start(purpose:)`を1度。再試行でも同じものを呼ぶ
  - `AnnouncementsModel`: セッションを始めたときに`start()`を1度、シートを開くたびに`appear()`
  - `ListMembershipModel`: シートを開いたときに`load()`

## 行に出す文言

- 行に出す文言は、SciaCoreから読む。UIで書くと、同じ行がUIによって違う文言になる
  - 投稿と通知の行: `PostTexts`（固定された投稿、「続きを読む」、注意書きとフィルターの警告、ぼかしの文言、投票のボタン、まとめた通知の「ほかN人」）、`ReplyLabel.title`、`QuoteDisplay.Reason.title`、`MediaCover.title(of:)`
  - 通知の文は`NotificationAppearance.phrase`、投票の票数と期限は`PollDisplay.summary`、一覧の空と終わりの文は`TimelineTexts`
  - 公開範囲の名前と記号: `VisibilityOption`の`title`と`symbolName`
  - フォローのボタン: `FollowState.buttonTitle`。検索の種類と候補の行: `SearchCategory.title`、`SearchSuggestions.Action`の`title`と`symbolName`
  - 各画面: `NotificationPolicy.Item`と`Value`、`FilterResult.Context`と`Action`、`ReportCategory`、`StorageBreakdown.Category`、`ConnectionDiagnostics.StreamingState.title(of:)`の`title`など、値の型に文言がある
- 値の型に結び付かない画面の文言は、画面ごとの`…Texts`にある。iOSのアプリは、使う人に見える文言をすべてここか値の型から読む（`make lint`の`user_text_outside_core`で止めている）ので、iOSの画面にある文言はどれもSciaCoreで見つかる
  - タイムライン: `TimelineScreenTexts`、`BatchActionTexts`（まとめてブースト）、`StreamingStatusTexts`（引っぱると見える接続の状態）、`ScheduledStatusTexts`、`SearchScreenTexts`、`AnnouncementTexts`、`EditHistoryTexts`、`MediaViewerTexts`
  - アカウント一式: `SessionTexts`（操作の失敗の見出しなど）、`HashtagChangeTexts`、`TabMenuTexts`、`NoticeTexts`、`OperationStatusTexts`、`StatusBarTickerTexts`、`LoginTexts`、`AccountSwitchTexts`、`CrashReportTexts`、`APIResponseTexts`、`InAppBrowserSheetTexts`
  - プロフィールとリスト: `ProfileTexts`、`AccountNoteTexts`、`ProfileEditTexts`、`ReportTexts`、`ListTexts`
  - 投稿欄: `ComposeTexts`。設定: `SettingsTexts`
  - 「キャンセル」「再試行」のような短い語も、画面ごとの`…Texts`に別々に置いてある。共通の定数はない

## 投稿

- 投稿欄は`ComposeModel`。`AccountSession.applyComposeDefaults(to:)`が済むまで`canPost`はfalseのまま。書き始めたときに待たせないよう、セッションを始めたら`preloadComposeDefaults()`で先に読んでおく
- 送れた結果（`onSubmitted`）は`session.statuses.reflect(_:usingTagsIn:)`に渡す。どの一覧へ配るかはそこで決まる
- 書きかけの投稿欄で返信、引用、編集、書き直しを始める前に、進むか、確かめるか、断るかは`Confirmation.starting(_:draft:now:)`が決める（共有されたもので書き始めるときは`Confirmation.shared`）。後から選んだ投稿の読み込みだけを使うのは`LatestLookup`
- 投稿欄の文言: 本文の上のラベル（返信先、引用元、編集、書き直し）は`ComposeModel.contextChip`、投稿ボタンの名前は`sendButtonTitle`、添付の状態は`ComposeAttachmentStatus.title`、絵文字のパレットの見出しは`EmojiPaletteSection.Kind.title`。添付を縮めた、ペーストした添付を足さなかった、ビューアでの添付の状態のチップは`Notice.mediaReduced(_:)`、`Notice.pastedMediaSkipped(_:)`、`Notice.draftStatus(_:progress:reduction:showFailure:)`
- メディアの口は`session.composeMediaService(makeThumbnail:)`、削除して書き直す口は`session.composeRedraftService()`。UIは、添付のサムネイルの作り方だけを渡す。ほかのアカウントで書くときは、`ComposeMediaService(client:settings:tuning:makeThumbnail:)`と`ComposeRedraftService(client:)`にそのアカウントのクライアントを渡す
- 投稿欄に渡すファイル（`LocalMediaFile`）は、`init(copying:in:mimeType:kind:)`でコピーして作る。`remove()`はファイルを置いたフォルダーごと消すので、使う人のファイルの場所を`init(url:mimeType:kind:)`にそのまま渡すと、そのファイルのあるフォルダーが消える
- リンクにタイトルを付けるときは、`PageTitleLoader`でページを読む。大きいページも、og:titleを読み終えるか上限（`ResponseLimit.pageTitle`）まで読み進める。付けられなかった理由は`LinkTitleFailure`
- 削除は、`Confirmation.deleting`で確かめてから`StatusDeletion.delete(_:onFailure:)`。どの一覧からも除き、投稿欄の編集や書き直しもやめる。ほかのアカウントの投稿を消したら、`ComposeModel.statusWasDeleted(_:accountID:willReset:)`をそのアカウントのIDで呼ぶ
  - `StatusDeletion`は、`init(session:composer:tasks:willResetComposer:)`で`ComposeModel`を渡して作る。削除を送る側から`ComposeModel`に届かない作りのUIは、`init(session:tasks:didDelete:)`で作り、`didDelete`の中で投稿欄へ伝える。同じ手順をUIで書き直さない
- 自分の投稿を引用できる人の変更は`QuoteControl.setPolicy(_:of:onFinish:)`、自分の投稿への引用の取り消しは、`Confirmation.revokingQuote(by:)`で確かめてから`QuoteControl.revoke(_:onFinish:)`。どちらも結果をどの一覧にも当てる。ある投稿を引用した投稿のタイムラインは、`SavedStatusesModel`を`.quotes(of:)`で作る（[quote.md](quote.md)）
- 引用できるか、引用を取り消せるかは、サーバーで違うので、`session.capabilities.quotes`（`QuoteRules`）に聞く。投稿の`quoteApproval`を直接見ない。投稿のメニュー（`StatusMenuTree`）には`capabilities`を渡す（[quote.md](quote.md)の「Fedibirdの形」）
- 新しく投稿するときの既定（公開範囲、引用できる人、言語、閲覧注意）の画面は`PostingDefaultsModel`。保存は`AccountSession.updatePostingDefault(_:)`を通り、`onPreferencesLoad`で届くので、そこで`applyComposeDefaults(to:)`を呼んで投稿欄に反映する（[account-screen.md](account-screen.md)）

## メニューと確認と失敗

- 何を出すかはSciaCoreが決め、UIは描くだけにする。確認は`Confirmation`、メニューは`MenuNode`（`StatusMenuTree`など）
- 受け持たない項目を外した並びは、`MenuLayout(defaultElements:)`で作る
- 失敗の文言は`ErrorPresentation`（`@_spi(FailureDisplay) import SciaCore`で読む）
- 押しても応答が届くまで画面が変わらない操作は、`SlowActivity.track(_:)`で囲み、`isSlow`の間は待っていることを知らせる。削除は`StatusDeletion.slowActivity`に渡す。待っていることを出すまでの長さ（`SlowActivity`と`LatestLookup(slowAfter:)`に渡す）は、`TuningCatalog.profileLookupChipDelay`から読む
- 付け外しの操作（お気に入り、ブースト、ブックマーク、会話のミュート、固定、リアクション）の失敗の見出しと、済んだことのチップの文言は、`StatusInteractions.Action`の`failureTitle(addsOnly:)`と`doneTitle(wasOn:)`。どの操作で済んだことを知らせるかは[object-actions.md](object-actions.md)の「結果の知らせ」にある。ほかのアカウントで行ったときは、`OtherAccountTexts.title(_:handle:)`でどのアカウントで行ったかを頭に付ける。相手との関係の変更は`UserRelationChange`の`doneTitle(_:)`と`failureTitle`、ミュートの期間の選択肢は`UserRelationChange.muteDurations`
- メニューを覚えている値でその場で組むためのキャッシュは`LatestValueCache`（自分のフィルターは`ServerFilterCache`）。読み込み中の行を出してから中身を差し替えずに済む
- 「リストに追加」の通信の口は`session.listMembershipAPI(accountID:acct:)`

## 設定

- 設定の画面に何を、どの順で、どんな名前で並べるかは、SciaCoreから読む。UIは節と行を上から描き、行の部品（スイッチ、選択、値の行）を選ぶ
  - トップの画面は`SettingsPage.rootSections(handle:)`、各画面の題は`SettingsPage.title`、親の画面の行に出す名前は`rowTitle`
  - 並びが決まっている画面（表示、操作、作成、メディア、リンク先の読み込み、情報）は`SettingsPage.sections`。行は、ほかの画面へ入る行（`.page`）か、その場で値を変える行（`.item`、`SettingsItem`）。UIが出せない行は除く
  - 対象の操作の画面（投稿、ユーザーなど）は`ObjectActionsScreen`。対象の名前と設定の場所は`ObjectEntity`
  - 選択肢の名前は、値の型の`title`（`AccentColorChoice`、`InsertionMotion`、`LinkBrowser`、`ReblogVisibility`、`ComposeBarIdle`、`MediaDynamicRange`、`ImageUploadSize`、`VideoUploadSize`）
  - ストレージの画面は、内訳が`StorageBreakdown`、消すボタンが`StorageRemoveTarget`
- 「投稿の見た目」と「通知の見た目」の分類と数値の項目は`AppearanceCatalog.groups`と`NotificationAppearanceCatalog.groups`、選んで決める項目は`AppearanceChoice`（分類ごとの並び、名前、部品、選べなくする条件、見本で示す場所）。分類の画面では、選んで決める項目を数値の項目より上に並べる
- プレビューに並べる見本は`AppearancePreviewSamples`と`NotificationAppearancePreviewSamples`。UIは、見本に使う画像を用意して場所を渡し（`PreviewSampleSources`）、`ImageStores`の`localData`で通信せずに返す
- iOSの見た目の設定で既定に戻す操作は、分類を並べた画面の「すべてデフォルトに戻す」（`AppearanceCatalog.resetAllTitle`）と、数値の行ごとの「デフォルトに戻す」の2つ。分類ごとに戻す操作はない
- 揃えて出すために応答を待つものは、`ResponseWait.limit`がたったら待つのをやめる（[vision.md](vision.md)の「想定外の応答への向き合い方」）

## SciaCoreにあるが、iOSの画面の作りに合わせた部品

`MediaBarSwap`、`TextMorphPlan`、`DragToDismiss`、`SpringDriver`、`FrameTicker`、`SpringScroll`は、iOSの画面の重なりや動きに合わせてある。UIKitをimportしないので別のUIでもビルドできるが、同じ画面の作りでなければ使わない。
