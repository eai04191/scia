# AGENTS.md

SciaはストリーミングAPIでタイムラインが流れる、手触りの良いiOS向けMastodonクライアントです。将来はmacOSにも対応します。何を作り、何を作らないかは[docs/vision.md](docs/vision.md)、作業の単位と順序は[docs/roadmap.md](docs/roadmap.md)を参照してください。

## 構成

- `project.yml`: XcodeGenの定義。`Scia.xcodeproj`と`App/Info.plist`は生成物なのでコミットせず、直接編集しない。ターゲットや設定の変更は`project.yml`で行う
- `Config/Local.xcconfig`: 署名のチーム（`DEVELOPMENT_TEAM = <チームID>`）など、人ごとに違うビルド設定を書く。コミットしない。なくてもシミュレーター向けにはビルドできる
- `Config/CacheLocal.xcconfig`: makeのDebugのビルドが使うコンパイルキャッシュの置き場所（`COMPILATION_CACHE_CAS_PATH = <フォルダー>`）を、人ごとに書く（`Config/Cache.xcconfig`が読む）。コミットしない。なければXcodeの既定の場所に置く
- `Config/app-info.json`: 謝辞、第三者のライセンス、Scia自身のリンク（プライバシーポリシーなど）の置き場所。ここだけを編集し、`make app-info`で`App/Sources/Settings/AppInfo.generated.swift`と`README.md`の`<!-- generated:... -->`の中を書き出す。書き出したものは直接編集せず、JSONと一緒にcommitする。合っているかは`make check`と`Tools/merge-queue.sh`で調べる
- `Packages/SciaCore`: UIに依存しないロジック（モデル、APIクライアント、ストリーミング、タイムラインの状態管理）。iOSとmacOSで共有するため、UIKit／AppKit／SwiftUIをimportしない。別のUIから何を使うかの入口は[docs/other-ui.md](docs/other-ui.md)。別のUIも使う部品を足したり、決まりをUIからSciaCoreへ移したりしたら、そのdocsにも足す
- `Config/app-info.json`の`contact`: クラッシュした投稿の報告の宛先（メールとMastodonのハンドル）。`make app-info`で`AppInfo.generated.swift`に書き出す
- `Packages/MemoryCache`: Sciaに依存しない、メモリに持つキャッシュ（`CostLimitedCache`）。SciaCoreとアプリが使う。SciaCoreに依存しないことを、パッケージを分けてコンパイラーで守る
- `Packages/TextKit2Label`: Sciaに依存しない、TextKit 2で文字を並べて描くラベル（`TextKitLabel`、`TextKitLabelLayout`、`LineFittingAttachment`）。アプリが使い、絵文字やリンクを扱うラベルはアプリで派生させる。Sciaの型を使わないことを、パッケージを分けてコンパイラーで守る。UIKitに依存するので、テストは`make test`でシミュレーターで走る
- `App/Sources`: iOSアプリ（UIKitライフサイクル）

## 文書の使い分け

- `docs/`はagentが読む文書で、人は読まない。人が読むのは`README.md`と`FEATURES.md`で、`docs/`とは別物として扱う
- `README.md`と`FEATURES.md`は、ユーザーが頼んだときだけ変える。機能を足した、roadmapの項目が済んだ、仕様のdocsを書いたといった作業のついでに書き足さない。載せたほうがよさそうなことは、書かずに報告でユーザーに聞く。`README.md`の生成の節は`Config/app-info.json`に合わせて変わるので、この決まりの対象外（mainに入れる前の承認は要る）
- `README.md`と`FEATURES.md`の変更は、ユーザーが自分の端末で`Tools/human-review.sh approve <commit>`を走らせて承認するまで、mainに入らない（`make hooks`のhookと`Tools/merge-queue.sh`で止める）。agentは承認を走らせず、`script`などで端末を作って入力を流し込むこともしない
- `FEATURES.md`: Sciaでできることのリスト。頼まれて書くときは、ファイルの先頭のコメントに従う
- `docs/vision.md`: 何を作り、何を作らないかと、設計の判断の基準。作業が終わっても残す考え方を書く
- `docs/roadmap.md`: これからの作業の単位と順序。1項目1行で、何をするかだけを書く。設計の判断や、作業を進めるための細かい合意・状態・調べて分かったことは書かない。済んだ項目は消す
- docs、コメント、commit messageに書く理由は、ユーザーが示したもの、ドキュメントやコードや実際の動きで確かめた事実、技術的な制約に限る。agentが推測した理由（使う人がどう使うことが多いかの見込みなど）は、ユーザーが決めたように読めるので書かない。読めば推し量れる理由なら、書かずに済ませる。推測でも書いておきたいときは、推測だと分かる書き方にし、報告でユーザーに確かめる
- 作業を別のthreadへ引き継ぐためのメモ（合意した細部、進み具合、検証の道具など）は、元のcheckoutの`.handoff/`に置く。`.git/info/exclude`で除いてあるのでcommitされない。worktreeは作業が終わると消えるため、worktreeの中には置かない。作業が終わったら消す。親子のセッションの間では使わない。始めるセッションへの依頼の文やメッセージで直接渡す

## コマンド

- `make generate`: Xcodeプロジェクトを生成する
- `make app-info`: `Config/app-info.json`から、アプリの`AppInfo.generated.swift`と`README.md`の生成の節を書き出す
- `make lint`: SwiftLintで強制アンラップ、`try!`、IUOを検出する（`brew install swiftlint`が必要）。呼び出しや文字列の補間の形で決まる規則は、構文木で調べる`Tools/SciaLint`で検出し、`// scialint:disable:next <規則>`で外す
- `make test-lint`: `Tools/SciaLint`の規則のテスト
- `make test-core`: SciaCoreのテスト（macOS上、シミュレーター不要）
- `make test-memory-cache`: `Packages/MemoryCache`のテスト（macOS上、シミュレーター不要）
- `make build`: シミュレーター向けにビルドする
- `make test`: シミュレーターでテストする。`SIM='<端末>'`で指定もできるが、貸し借りする端末（`Scia 1`〜`Scia 4`）は借りているものしか受け付けない。端末のiOSの版で初めて走らせたときは、UIKitの公開されていない作りに頼る部分のUIテスト（`SciaSystemUITests`）も走らせる。通ると、確かめた作業ツリーの中身を覚える
- `make test`の記録: 全部を走らせると、`DerivedData/test-logs/watch-<時刻>`に実行中の負荷（`load.log`）と、30秒たっても終わらないSciaCoreのテストのスタック（`<テストの名前>.sample.txt`）が残る。落ちた回の`.xcresult`は`DerivedData/test-logs/failed-<時刻>`に残る
- `make test ONLY='SciaTests/LinkLabelTests'`: 一部のテストだけを走らせる。手元で走り、このworktreeが借りている端末を使うので、先に借りる。識別子は空白で区切って複数渡せる。通っても中身は覚えない。`xcodebuild ... test`を直接走らせるときは、`-collect-test-diagnostics never`を付ける。付けないと、テストが失敗したときにシミュレーターの診断を集め、応答を待って10分止まる
- `make check`: 変更を報告する前に必ず通す。通ると、確かめた作業ツリーの中身（commitしていない変更も含む）を覚える
- テストが落ちたら、`DerivedData/test-logs/failed-<時刻>`のxcresultを`xcrun xcresulttool get test-results tests --path <xcresult>`で読む。別のMacで走った分も手元のここに届く。式の実際の値は`make test`の出力に残らず、ここにある
- `make check-test`: `make check`と`make test`を両方走らせる。アプリをビルドしてから、checkの残りを`make test`と同時に走らせるので、続けて走らせるより早い。端末の選び方と、通ったものを覚えるのは、それぞれと同じ
- `make test`、`make check`、`make check-test`は、`SIM`も`ONLY`も指定しなければ、テストを任せる別のMacと手元の、空いている枠で走らせる。端末は借りなくてよい。別のMacを優先し、どちらも満杯なら先着順に待つ。手元で走らせるときは`SCIA_REMOTE_TEST=local`を付ける（[docs/test-dispatch.md](docs/test-dispatch.md)）
- `make menu-editor`: メニューの既定の並びを並べ替えるページを、今の項目の名前と既定の並びを入れて`DerivedData/menu-editor.html`に書き出す
- `make archive`: 実機向けのReleaseビルドをアーカイブする。ビルド番号はアーカイブしたUTCの日時になる
- `make testflight`: アーカイブしてApp Store Connectへ上げる。mainは、GitHub Actions（`.github/workflows/testflight.yml`）が毎朝5時（JST）に、前に上げたときから変わっていれば上げる。上げたビルドは、`make testflight-external`で外部テストのグループ（リポジトリのvariablesの`TESTFLIGHT_EXTERNAL_GROUP`）に足し、TestFlight App Reviewに出す
- `make hooks`: ローカルのmainを、`make check`と`make test`の両方が通った中身のcommitにしか動かさないhookを入れる。checkoutごとに1回で、worktreeにも効く。通った中身との違いがMarkdown（`*.md`）とログイン画面の補完に使うサーバーのリスト（`known-servers.txt`）だけなら、走らせ直さずに通ったものとして扱う
- `make scenario-run PERSONA=<役>`: 何も知らないエージェントを、`Tools/scenario/personas/`の役で初めて使う人としてSciaに触らせ、報告とスクリーンショットを`~/scia-scenario/runs/`に残す。外へ出ないMastodon（`mastodon.localhost`）と専用の端末`Scia Scenario`を使い、Release構成のSciaを入れる。先に`make scenario-setup`で準備する（何度走らせても同じ状態になる）。DockerとAXe（`brew install cameroncooke/axe/axe`）が要る。ユーザーが`/scenario`で起動したときは、`.claude/skills/scenario`の手順で走らせてまとめる

## シミュレーター

- 動作確認とテストには、`Scia 1`、`Scia 2`、`Scia 3`、`Scia 4`のどれかのシミュレーターを使う。どれもログイン済みの端末の複製で、ログイン情報が端末のKeychainに残っているため、ログインし直さずに済む
- `Scia Scenario`は`make scenario-*`の専用の端末で、`Tools/sim.sh`では貸し借りしない。ほかの確かめには使わない
- 端末は4台なので、シミュレーターを触る間だけ借りる。触る直前に`sim`のskillで`Tools/sim.sh acquire`を走らせて借り（空きがなければ空くまで待つ）、触り終えたら`Tools/sim.sh release`で返す。借りた端末をほかのworktreeが使ったあとなら、`Tools/sim.sh reset '<使う端末>'`でアプリの設定を既定に戻し、自分のビルドを入れ直す
- 端末のクリップボードには、自分が`xcrun simctl pbcopy`で入れたもの以外をペーストしない。DeviceHubの「Use Shared Clipboard」がオンだと、Macのクリップボードが端末へ書き込まれ、Universal Clipboardで届いたユーザーのiPhoneのコピーも入るため、投稿欄に貼ると仕事の内容が投稿される。`Tools/sim.sh acquire`は、借りた端末の同期を切ってクリップボードを空にする。投稿欄の本文と添付は、ペーストではなく`scia-debug://compose`の`text`と`media`で入れる。ペーストそのものを確かめるときは、貼る直前に`pbcopy`で中身を入れる
- 端末の設定は、ほかのスレッドが変えたり、借りるときに既定に戻したりする。確かめに要る設定（チューニング、タップや長押しの操作、見た目など）は、前に入れたものが残っている前提にせず、確かめる直前に入れる
- シミュレーターのツールでは、決まった端末を毎回`device`で指定する。省略すると、他のスレッドが使っている端末を操作してしまうことがある
- 並行して作業するスレッドは、worktreeも分ける。`make build`・`make test`はworktree直下の`DerivedData`、`make test-core`は`Packages/SciaCore/.build`を使うため、同じworktreeで同時に走らせると、ロック待ちで失敗したり成果物を上書きし合ったりする
- 4台は同じアカウントでログインしているため、サーバー上の状態は共有される。読んだ位置は`api/v1/markers`でサーバーに保存され、起動時に読み込まれるので、別のスレッドがスクロールすると次の起動位置が変わる。投稿やブーストも、ストリーミングで他の端末に流れ込む。起動時の位置や新着の挙動を確かめるときは、他のスレッドの操作で結果が乱れていないか疑う
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- `Scia 1`〜`Scia 4`は、メモリを減らすため、[simslim](https://github.com/MobAI-App/simslim)で写真以外の使わないサービスを止めている（`simslim on <UDID> --except photos`）。プッシュ通知、ユニバーサルリンク、iCloud、Spotlight、言語のデータの読み込みなどは、エラーを出さずに動かないことがある。こうした機能が動かないときは、Sciaの不具合と決める前に`simslim status <UDID> --dropped`で止めているサービスを確かめる。要る分類（`simslim profiles`）があれば、`simslim on <UDID> --except photos,<分類>`で残して入れ直し（端末は再起動する）、確かめ終えたら`--except photos`で入れ直す。設定は端末を再起動しても消えないが、`xcrun simctl clone`で作った端末には引き継がれない
- 画面は`Tools/sim.sh dump '<使う端末>'`で文字として読む。アプリの中でアニメーションとスクロールの慣性が止まるのを待ってから（多くは1秒ほど）、要素の名前と中心の座標（タップと同じポイント）、タイムラインの`contentOffset.y`などの状態を出す。初回は、アプリに要素を作らせる設定を端末に入れ、起動し直しを求める。この設定でアプリが少し重くなるので、hitchを測るときは`xcrun simctl spawn '<使う端末>' defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled`で外す
- 見た目を確かめるときは、シミュレーターのツールの`screenshot`ではなく`Tools/sim.sh shot '<使う端末>'`で撮る。画面が止まるのを待ってから、端末のポイント幅に縮小したJPEGを出すので、画像の座標がそのままタップの座標になり、1枚のトークンも約1/5になる。`--crop x,y,幅,高さ`で一部を切り出し、`--full <ファイル>`でユーザーに送る原寸のPNGも残す。原寸は自分では読まない
- 画面は、タップでたどらず`xcrun simctl openurl '<使う端末>' '<URL>'`で開く。アプリの画面は`scia://`のURLで開き、デバッグ版だけの画面と操作は`scia-debug://`で開く。`scia-debug://reset`（重ねた画面を閉じてホームに戻す）のあとに続けて送ってよい。閉じ終えてから開く。IDやハンドルは、ログインしているサーバー（stellaria.network）の公開API（`api/v1/accounts/lookup?acct=`、`api/v1/accounts/<ID>/statuses`）で調べる。画面を足したら、`AppDestination`に開く先を足し、このリストにも書く。`scia://`のURLは、これから足すショートカットと同じ入り口を通る
  - タブ: `scia://tab/<home|local|federated|notifications|search|bookmarks|favourites|scheduled|followed-tags>`。足したタブは`tab/list?id=<リストのID>`、`tab/hashtag?name=<名前>`、`tab/profile?acct=<ハンドル>`、`tab/account-hashtag?acct=<ハンドル>&name=<名前>`。並びにない、または無効にしているタブでは何もしない
  - 設定: `scia://settings`。設定のトップの画面から入る画面は`settings/<画面>`で、トップの画面の上に重ねて開く（戻るとトップの画面に戻る）。分類の中の画面は、分類の画面を挟んで重ねる。分類は`display`（表示）、`interaction`（操作）、`compose`（作成）、`about`（情報）。画面は`account`（アカウントの画面）、`app-icon`（アプリのアイコン）、`appearance`（投稿の見た目）、`notification-appearance`（通知の見た目）、`media`（メディア。表示の中）、`link-loading`（リンク先の読み込み）、`auto-translation`（自動翻訳）、`tabs`（タブ）、`<status|quoted-status|notification|user|link|external-post|hashtag|media|reaction>-actions`（操作の各対象。タップと長押しとメニュー）、`<status|user|link|external-post|profile-text|hashtag|media|reaction>-menu`（メニューの各項目。プロフィールの文章のほかは、対象の画面も挟んで重ねる）、`status-action-bar`（投稿のアクションバーのボタンの並び。投稿の操作の画面も挟んで重ねる）、`status-leading-swipe`と`status-trailing-swipe`（投稿を右にスワイプと左にスワイプして出すボタンの並び。投稿の操作の画面も挟んで重ねる）、`compose-tools`（投稿欄のボタン）、`connection`（接続の状態。情報の中）、`connection-timelines`（受信中のタイムライン。接続の状態も挟んで重ねる）、`storage`（ストレージ）、`storage-viewed`と`storage-prefetched`（ストレージのメディアのキャッシュの表示済みと先読み）、`licenses`（ライセンス。情報の中）、`acknowledgments`（謝辞。情報の中）。「投稿の見た目」の分類の画面は`settings/appearance/<分類>`で、分類は`row`、`context`、`avatar`、`name`、`body`、`spoiler`、`media`、`linkCard`、`xPost`、`poll`、`reactions`、`actionBar`、`reactionGlow`。「通知の見た目」の分類の画面は`settings/notification-appearance/<分類>`で、分類は`group`、`header`、`symbol`、`account`、`quoted`、`context`
  - プロフィール: `scia://profile/<user@domain>`（ホームのタブに開く）、`scia://my-profile`（選んでいるタブに自分のプロフィールを開く）、`scia://profile-edit`（自分のプロフィールの編集）、`scia://note?acct=<ハンドル>`（その人へのメモ）、`scia://report?acct=<ハンドル>`（その人の通報。送らなければサーバーに届かない）
  - 人のリスト: `scia://accounts/<followers|following>`（自分の。`?id=<アカウントのID>`でその人の）、`scia://accounts/<favourited|reblogged>?id=<投稿のID>`（その投稿をお気に入り、ブーストした人）、`scia://accounts/emoji-reactioned?id=<投稿のID>&name=<パーセントエンコードした絵文字>`（その投稿にその絵文字でリアクションした人）
  - タイムライン: `scia://hashtag?name=<名前>`（ハッシュタグ）、`scia://account-hashtag?acct=<ハンドル>&name=<名前>`（その人のハッシュタグ）、`scia://scheduled`（予約投稿。タブを無効にしていれば手前に重ねる）
  - 投稿: `scia://thread?id=<投稿のID>`（スレッド）、`scia://edit-history?id=<投稿のID>`（編集履歴）
  - 検索: `scia://search?q=<パーセントエンコードした語>`（検索のタブに語を入れて確定する。`q`がなければタブを開くだけ。検索を無効にしていれば選んでいるタブに積む）
  - 投稿欄: `scia://compose/<tools|language|schedule|emoji|media-picker>`（書き始めて、ボタンの並び、言語、予約の日時、絵文字のパレット、メディアのピッカーを開く。予約していなければ予約を始める）、`scia://compose/<attachment|alt-text|crop>?index=<n>`（n番目の添付のビューア、その代替テキストの入力、切り抜き。先に`scia-debug://compose?media=<枚数>`で添付を足す）
  - アカウントの画面: `scia://account`（シートで開く。設定に重ねるのは`scia://settings/account`。決まりはdocs/account-screen.md）
  - サーバーのお知らせ: `scia://announcements`（お知らせのシート）
  - 保留中の通知: `scia://notification-requests`（通知のタブに保留中の通知を送ってきた人のリスト）、`scia://notification-request?id=<保留中の通知のID>`（その上にその人からの通知）、`scia://notification-policy`（通知のフィルタリングの設定）。IDは`api/v1/notifications/requests`で調べる。ダミーのセッションでは`dummy-request-1`〜`3`
  - そのほか: `scia://crash-report?id=<投稿のID>`（隔離した投稿について開発者に送る内容の画面。決まりはdocs/crash-quarantine.md）、`scia://operation-status`（操作の状況）、`scia://in-app-browser-height`（重ねた画面を閉じ、ホームの上にアプリ内のSafariの高さを選ぶシートを出す。`?return=<設定の画面>`で、閉じたときにその設定の画面を開き直す）
  - デバッグ版だけ: `scia-debug://viewer?index=<n>`（選んでいるタブで一番上に見えている画像付きの投稿を、n番目の添付ファイルでビューアに開く。代替テキストの全文はビューアの「代替テキスト」から開く）、`scia-debug://profile-edit?crop=<avatar|header>`（ダミーの画像でアイコンかヘッダー画像の切り抜きを開く）、`scia-debug://discomfort-report`（違和感レポート）、`scia-debug://tuning`（チューニング）、`scia-debug://catalog`（部品カタログ）
- 絵文字のリアクション（Fedibirdの拡張、docs/emoji-reaction.md）の実物は、`Scia 4`に保存してあるFedibirdのアカウントで確かめる。`Tools/sim.sh acquire 'Scia 4'`で端末を指定して借り、`xcrun simctl openurl 'Scia 4' 'scia-debug://account?acct=<ハンドル>'`で、メニューを触らずに保存してあるアカウントに切り替える。付け外しは、ほかの人に通知が届かないよう、そのアカウントの自分の投稿で試し、確かめたら外す。リアクションの通知は`Tools/inject/notification-emoji-reaction.json`を流して見る
- `xcrun simctl openurl '<使う端末>' 'scia-debug://dummy-session'`で、通信しないダミーの投稿と通知でホームと通知の画面に入れる。ログインしていない端末（機種ごとに作る一時的な端末など）でも、ログイン済みの端末でも入れる。ログイン画面のデバッグ用のボタン「ダミーのデータで入る」でも入れる。ログイン済みの端末では、アカウントのメニューにダミーのアカウントが並び、本物のアカウントを選ぶと戻る。Keychainには保存しないので、起動し直すと保存してあるアカウントかログイン画面に戻る。投稿への操作はサーバーに届かず失敗する。新しい端末では、最初にURLを送ったときに「“Scia”で開きますか？」が出るので、一度「開く」を押す必要がある
- URLを送ったあとや操作のあとに`sleep`しない。`dump`と`shot`が画面が止まるまで待つので、続けて行うコマンドは1つのBashの呼び出しにまとめる（例: `xcrun simctl openurl '<使う端末>' 'scia-debug://reset' && Tools/sim.sh dump '<使う端末>'`）
- タップやスワイプのあとは、dumpで結果を確かめてから次へ進む。思った画面でなければ、同じ座標を打ち直さず、dumpから座標を取り直す
- 画像の読み込みのように、動きのないまま中身が後から入る表示は、止まっていても終わっていない。目的の要素が出るまでdumpし直す。ダミー投稿の画像は、流してから1〜2秒で入る
- 写真のピッカーは別のプロセスが描くので、`sim.sh`はその表示を待たない。アプリを起動して最初に開いたときだけ、表示まで数秒かかる。撮った画像にピッカーが写っていなければ、dumpで`mediaPicker: shown`を確かめて、数秒後に撮り直す
- 投稿欄の本文は、シミュレーターのツールの`text`やクリップボードで入らないことがある。`xcrun simctl openurl '<使う端末>' 'scia-debug://compose?text=<パーセントエンコードした本文>'`で、書き始めて本文を置き換える。打ったときと同じく、末尾の語の補完も出る。`scia-debug://compose/close`で、下書きを残してカプセルに戻す。`scia-debug://compose/open`で、下書きを変えずにカプセルを押したときと同じく書き始める。`scia-debug://compose/reply?file=<ファイル名>`で、`inject`と同じ置き場所のファイルにある最初の投稿へ返信を始める。`&media=<枚数>`を付けるか`text`の代わりに渡すと、番号を描いた色違いの画像（1枚目から赤、青、オレンジ、紫）を添付に足す。ペーストと同じ経路でサーバーに送る。`&poll=<パーセントエンコードした選択肢を,で区切る>`を付けるか`text`の代わりに渡すと、投票の欄を出して選択肢を置き換え、フォーカスは本文に残す。選択肢は日本語のキーボードで打つと崩れるので、これで入れる。ピッカーは、ピッカーそのものを確かめるときだけ使う
- 自分のプロフィールの編集は、`xcrun simctl openurl '<使う端末>' 'scia://profile-edit'`で開く。日本語のキーボードでは半角の`:`や`@`を打てないので、補完を確かめるときは、`scia-debug://profile-edit`に`?note=<パーセントエンコードした本文>`で自己紹介を、`?field=<パーセントエンコードした本文>`で足す補足情報の内容を、補完したい語（`@agent_testin`や`:chigau_0`など）にして開く。打ったときと同じく、末尾の語の補完が出る
- タイムラインの一番上にいると、新着で行が下へずれ、dumpで読んだ座標が古くなる。タイムラインの行をタップする前に`scia-debug://arrivals/hold`を送ると、ホームと通知のタブは新着を挿入せずに溜める。終わったら`scia-debug://arrivals/release`で、溜まった新着をまとめて挿入する。ストリーミングはつないだままなので、`streaming/offline`と違って、切断の表示やポーリングでタイムラインが動かない。再接続などで新着を読む補完も、解くまで見送る。投稿の編集や削除と、保留を送る前に始まっていた補完の結果は、すぐ反映される
- ハードウェアキーボードがつながった扱いだと、ソフトウェアキーボードが出ない。キーボードが出た状態を確かめるときは、`make sim-keyboard`で、借りている端末のハードウェアキーボードを外す。フォーカス済みの入力欄にも出るが、出るまで少しかかるので、直後のスクリーンショットで判断しない。`KEYBOARD=hardware`を付けるとつなぎ直す

## 設計原則

- ロジックはできるだけSciaCoreに置き、`swift test`で検証できる形にする。アプリ側はSciaCoreの状態を描画するだけの薄い層に保つ
- 非決定的な外部依存（今の時刻、時間の経過、乱数、UUID、通信、ファイル、OSの状態など）は、ロジックの内部で直接生成・取得せず、テストで差し替え可能な境界に集約する
- 時間をおく処理は、標準の`Clock`（`any Clock<Duration>`）で受け取る。待つ関数や独自の時計の型で受け取らない。期限や残りの長さは`stopwatch(on:)`で測る。日付としての今が要るときは今の日付を返す関数を、Core Animationの時間が要るときはその時間を返す関数を受け取る
- 実物の時計、今の日付、Core Animationの時間を作るのは、SciaCoreの`SystemTime`とアプリの`AppDependencies`だけにし、ほかは既定値としてそこを参照する（`make lint`の`direct_time_access`で止める）。デバッグ用のコード（`App/Sources/Debug`）は対象外
- セッションの持ち物（各タイムライン、開いた画面、投稿欄）で始める処理は、セッションの持ち主（`TaskScope`）の子で始める。ログアウト、アカウントの切り替え、窓を閉じたときに、止める処理を並べなくても止まるようにするため（`make lint`の`session_task_outside_scope`で止める）
- タイムラインはUICollectionViewとdiffable data sourceで組む。スクロール位置を細かく制御する必要があるため、SwiftUIのListやScrollViewにはしない
- 独自のアニメーションやジェスチャーを足す前に、UIKit標準の部品と挙動で実現できないか検討する
- UIKitの動きは、SwiftUIのスプリング（`.smooth`、`.snappy`など）を`UIView.animate(_:changes:completion:)`に渡して書く。途中で止める、逆向きにするなど`UIViewPropertyAnimator`で動かすときは、`UISpringTimingParameters(duration:bounce:)`で同じスプリングにする。`UIView.animate(withDuration:)`の既定の加減速や`usingSpringWithDamping`では書かない。SwiftUIの部品と動きが揃わず、そこだけ古い動きに見えるため。前の書き方で残っている動きは、その箇所に手を入れるときに置き換える。ただし、OSから渡る時間と曲線に合わせる動き（キーボードの出入りに付いて動く投稿欄など）は、渡された値のまま動かす。スプリングの進み具合を自分で計算して、ほかの値を付いて動かしている部分（ステータスバーの通知の中身は、`UIKitSpring`でUIKitのスプリングを計算している）は、動きと計算を一緒に置き換える。片方だけ替えると、付いて動く値がずれるため
- 画面の骨格、スクロール位置の制御、入力（入力欄、変換、キー操作、フォーカス）、ジェスチャーはUIKitで作る。中に入力もスクロール位置の精密な制御も持たない表示の部品は、SwiftUIで作れないかを先に考え、UIKitの画面に`UIHostingController`で載せる。Liquid Glassの組み方（`glassEffect`、`ConcentricRectangle`、`.containerShape`）をそのまま使えるため。補完の候補のリストでは、UIKitの`containerConcentric`がスクロールに追従しなかったが、SwiftUIでは追従した
- 人が書く文字の入力欄は`GlyphLanguageTextView`か`GlyphLanguageTextField`で作る。この2つはスマート挿入（`smartInsertDeleteType`）を切ってあり、ほかのUIKitの入力欄（検索欄、アラートの入力欄など）では`smartInsertDeleteType = .no`を入れる。スマート挿入は、英字の後ろに「─」を貼ると「abc ─」のように、ペーストした文字の前に空白を足すため。SwiftUIの入力欄（`TextEditor`、`TextField`、`.searchable`）は、SwiftUIから切れない
- 設定のような`Form`や`List`の行は、iOSの設定アプリに倣い、押せるかどうかを行の形で示す。名前と値の行は見るだけ、シェブロンの行はほかの画面へ入る、名前だけの行はボタンにする。ボタンの行には値を並べない。押せることを色だけで示すと、アクセントカラーのモノトーンで押せない行と見分けられなくなり、iOSの「ボタンの形」もこの行には効かないため
- 設定で項目が1つのセクションの見出しは、行の名前に情報を足すときだけ付ける（「ブースト」の見出しの「公開範囲」など）
- 設定のトップの分類は、見る（表示）、触る（操作）、書く（作成）の場面で分ける。アプリのアイコンはホーム画面のアイコンを変える設定で、範囲が違うので「表示」に入れない
- UIKitで作った部品でLiquid Glassの不都合が出たら、SwiftUIへの置き換えを候補に入れる。UIKitとSwiftUIの境目では、`UIViewRepresentable`の中身が大きさの希望を変え続けて並べ直しが止まらなくなることがあるので、包む部品は`sizeThatFits`で大きさを決める
- Mastodon APIの仕様は推測せず、公式ドキュメント（https://docs.joinmastodon.org/ ）で確認する。サーバー実装による差異（glitch-soc、Fedibird、GoToSocialなど）は、必要になった時点で個別に対応してテストに残す
- サーバー（ほかのサーバーの利用者が書いた投稿や、fxtwitterの応答を含む）から来る件数、上限、URLは、読むところで確かめる。件数は`decodeCount`で範囲に収め、上限は`ServerLimit`で1以上だけを受け付け、URLは使い道（読み込む画像やメディアか、押して開く先か、ストリーミングの接続先か）ごとに`decodeURL`でスキームを確かめる（`make lint`の`server_value_without_check`で止める。コンパイラーが作るDecodableに`Int`や`URL`のプロパティを書いて読むのは、`synthesized_server_value_decoding`で止める）。読んだあとの計算でも、サーバーの値から作った数（縦横比や割合）を整数に直す前に、範囲に収める
- ファイルやフォルダーの名前は、文字列の決まった名前でなければ`SafeFileName`で作り、`appending(fileName:)`でつなげる。URLやサーバーの応答、ほかのアプリから受け取ったファイルの名前には、`/`や`..`が入りうるため（`make lint`の`unsafe_file_name`で止める）
- ログに何を`privacy: .public`で出してよいかは[docs/logging.md](docs/logging.md)に従う。ハンドル、本文、URL、応答の本文、`localizedDescription`を公開扱いで出す書き方は、`make lint`の`log_private_value`で止める。違和感レポートの状態ダンプも同じ決まりで書く
- サーバーの上限のうち、APIで返らないもの（メモや通報のコメントの文字数など）は、Mastodonのソースにある値でも手元で固定しない。Mastodonはソースを変えて動かせるので、上限を変えたサーバーで、書ける長さを手元で止めたり、断られる長さを通したりするため。手元では止めず、サーバーが断って返す理由を、送れなかったときの表示で出す。文字数のような目安は、上限を付けずに出してよい
- 通信は`HTTPClient`を通す（APIの外は`AppDependencies.http`、ストリーミングは`StreamingClient`）。再開の時刻で止める、一時的な失敗で送り直す、応答の大きさの上限、httpとhttps以外を開かない決まりを、すべての経路で守らせるため。URLSessionを`URLSessionTransport`の外で使う書き方は、`make lint`の`url_session_outside_network_layer`で止める。決まりは[docs/network.md](docs/network.md)にある
- 失敗の理由（`ErrorPresentation`）は、`App/Sources/Notices/FailureDisplay.swift`の部品で出す。ログアウトされたアカウントがあれば、部品が「ログインし直す」を付けるため。文言はSciaCoreでSPI（`FailureDisplay`）にしてあり、部品のファイルのほかでそのSPIをimportする書き方は、`make lint`の`failure_reason_outside_display`で止める
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 文言

- 使う人に見える文言は、iOSの日本語UIの標準の言い回し（設定アプリ、メール、Safariなどの表記）に倣う。前に直した言い回し（「既定」「捨てる」「消す」「止める」「端末」など）は、`make lint`の`ios_wording`で止める。規則が並べていない言い回しも、同じ操作をiOSがどう書くかを確かめてから書く
- 使う人に見える文言の引用は`“”`で書く。iOSの設定アプリの書き方に合わせるため
- 状態の文言の「中」は進行中だけに使い、完了した状態は「接続済み」のように「済み」と書く。「接続中」が、つないでいる途中とつないだあとのどちらにも読めたため
- 「接続の状態」の画面（`ConnectionStatusView`）は開発者が見る画面なので、ポーリングなどの用語をそのまま使う
- 使う人に見える文言では、対象が画像だけなら「画像」、動画・GIF・音声を含むなら「メディア」と書く。代替テキストや閲覧注意のように種類を問わず付くものを、「画像」と書かない
- ユーザーの`acct`（`@user@domain`）は、使う人に見える文言では、Mastodonのwebに倣って「ハンドル」と書く。「ユーザー名」や「acct」と書かない
- 使う人に見える文言では、フォローをやめる操作を、ユーザーでもハッシュタグでも「フォローを外す」と書く。「フォローをやめる」「フォロー解除」と書かない。同じ操作を対象によって別の言葉で書かないため
- 投稿がサーバーのフィルターに該当することは、「当たる」ではなく「一致する」と書く。使う人に見える文言だけでなく、コメント、テストの説明、カタログの見出しも揃える。残しておくと、あとの作業がその言い方に引きずられるため
- コメント、docs、テストの説明、カタログやチューニングの見出しでは、iOSやプログラミングで通じる用語を使い、和語に言い換えない。「払う」は「スワイプ」、「弾み」「ばね」は「バウンス」「スプリング」、「札」は添付ファイルなら「バッジ」・返信先や編集なら「ラベル」、閲覧注意の「覆い」は「ぼかし」、「畳む」は「折りたたむ」、「台本」は「シナリオ」、辞書の「鍵」は「キー」と書く。「印」は1語で済ませず、アイコン、チェックマーク、記号、インジケーターなど指すものの名前で書く

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

見た目と動きは、どのコマを止めても、そのまま人に見せられる1枚になっているかで判断する。いちばん厳しいデザイナーが、どれかのコマのスクリーンショットに「これは何？」と添えて送り返してくる場面が思い浮かぶなら、それが次に直すところ。以下の項目は、この基準で見るときの例で、項目を見終えても確かめ終えたことにはならない

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、タイムラインの上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- タイムラインの行を足す・消す・描き直す経路を足したら、[docs/vision.md](docs/vision.md)の「タイムラインの動き」のどれに当たるかを決め、`setEntries`の`animatesRemoval`などで渡す。使う人の操作で消えるのに動かない、操作によらない変化で読んでいる行が動く、のどちらも起こさないよう、動くかどうかをテストに残す
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中にスワイプする、閉じた直後に別の画像をタップする、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- トランジションの品質チェック: 本物のビューの代わりに複製を動かす開閉（ビューアの開閉、投稿欄とカプセルのあいだなど）を足したり変えたりしたら、動き始めと着地の両端で、複製と本物の見え方が一コマで切り替わらないかを確かめる。見比べる項目は、位置と大きさ、角度、角の丸み、フチ（太さと色）、影（下の面に落とす影と、重なったもの同士の影）、中身（画像か下地か、濃さ、暗さ）、上に重ねた表示（バッジ、再生アイコン、ぼかし）、重なり順（手前にあるはずのものが手前にあるか）、まわりのビュー（隠した本物が残す空き、隣の写真）。どれも、複製を本物に近づけるにつれて本物の見え方へ移すか、着いてから浮かび上がらせる。確かめるときは、時間を伸ばして録画し、両端の前後数コマを切り出して並べ、項目ごとに見る。動いている途中のコマだけを見て済ませない。テストでは、両端で複製の見え方が本物と同じになっていることを確かめる
- 動きの録画: `xcrun simctl spawn '<使う端末>' defaults write net.mizle.scia tuning.<項目のid> -float <値>`でチューニングの値（閉じる時間など）を一時的に伸ばし、`xcrun simctl io '<使う端末>' recordVideo --force <ファイル>`をバックグラウンドで起動して録画し（`pkill -INT -f "recordVideo --force <ファイル>"`で止める。ファイルで絞らないと、他のスレッドの録画まで止めてしまう）、ffmpegの`fps=30,crop=...,tile=...`でコマを並べて見る。見たい部分（バーの付近など）を切り出して連続したコマで比べると、1コマだけの切り替わりにも気づける。確認が終わったら`defaults delete`で必ず戻す
- シミュレーターのツールの`touch_path`は、同じ座標の点を動きとして送らない。最後に同じ点を並べて指を止めた形にしても、離した瞬間の速さが残って慣性で流れる。位置を決めたいドラッグには、終点で細かく揺らして速さを0にする`Tools/sim.sh drag <x1> <y1> <x2> <y2>`の点の並びを渡す。最初の20〜80ptはスクロールが始まるまでの遊びに吸われるので、動かしたあとに`contentOffset.y`を測って足りない分を足す。ページめくりやスワイプして閉じる操作は、速さで決まるので`swipe`で行う
- どこを押すとどのビューが受けるかは、`xcrun simctl openurl '<使う端末>' 'scia-debug://hit-areas/on'`で、すべての画面の上に、受けるビューごとに色を分けた範囲と型の名前を重ねて見る。デバッグメニューの「当たり判定を表示」でも切り替えられ、`hit-areas/off`か起動し直すと消える。範囲は`hitTest`で調べるので、アニメーションの途中も行き先の位置に出る。タイムラインの画面では調べて描き直すのに2秒ほどかかり、その間は前の結果を出しておくので、画面を移ったりスクロールしたりした直後は、撮り直して確かめる。SwiftUIの部品の中は1つの範囲になる
- タップが効かないなど、どのビューが触れたものを受けているか分からないときは、lldbで実行中のアプリにつなぎ（`lldb -p <pid> --batch -s <コマンドのファイル>`）、`expr -l swift -O -- `でウィンドウの`hitTest`やビュー階層（`recursiveDescription`）を調べる
- ビューアの確認には、デバッグメニューのダミー投稿（形の違う4枚、縦長1枚、画面より小さい3枚、透過画像1枚、動画とGIF、音声付きの長い動画）を使う。通信せずにタイムラインの一番上に出せる（起動し直すと消える）。動画とGIFは初回だけ端末で書き出すため、少し遅れて流れる
- agentはメニューを開かず、起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://dummy/<種類>'`でダミー投稿を流す。種類は`arrivals`（新着10件）、`images`（4枚）、`tall`（縦長1枚）、`small`（画面より小さい3枚。3枚目は元の大きさを付けない）、`transparent`（透過画像1枚）、`video`（動画とGIF）、`long-video`（経過した秒数を描いた90秒の動画。音声トラックは付くが無音）、`link-card`と`link-card-image`（リンク先だけのカードで流し、5秒後に通信せずに画像のないカード、画像付きのカードを届ける。届いたときの動きを、動きの途中の操作と合わせて確かめる）、`link-card-sensitive`（`link-card-image`を閲覧注意の投稿で流す）、`x-post`（Xの投稿へのリンクだけのカードで流し、5秒後にfxtwitterに頼まずに、4枚の画像付きのXの投稿を届ける。囲みは設定の「表示」の「リンク先の読み込み」で「Xの投稿を展開」がオンのときだけ出る）、`filtered`（サーバーのフィルターに一致した4件を流す。警告、警告と注意書き、添付ファイルのぼかし、隠すの4つで、隠す1件はタイムラインに出ない）、`animated-emojis`（動くカスタム絵文字を8個ずつ入れた40件。絵文字はmisskey.ioの実物なので通信が要る）、`polls`（投票の付いた4件。複数選べない、複数選べる、締め切るまで票数を隠す、締め切った投票。投票と更新は通信せず、1秒待ってから票を足した結果を返す）、`quotes`（引用のある4件。引用元に画像と入れ子の引用、引用元に注意書き、承認待ち、ミュートしている人。引用元もサーバーにないので、囲みを押して開くスレッドは読み込めない）、`reactions`（絵文字のリアクションの付いた4件。1つ、折り返すほど多い、カスタム絵文字とほかのサーバーのカスタム絵文字、数の大きいもの。列はサーバーが絵文字のリアクションに対応しているときだけ出る。投稿はサーバーにないので、付け外しは失敗して戻る。ほかの人のリアクションの数の変化は、`scia-debug://emoji-reaction?name=<パーセントエンコードした絵文字>&count=<数>`で、選んでいるタブで一番上に見えている投稿に、ストリーミングと同じ経路で当てる。`me=1`で自分がしたもの、`count=0`でなくなる）。アプリが起動していないときに送ると、アプリは起動するがダミーは流れない
- 実データにない投稿や通知の見え方は、APIの応答と同じ形のJSONを、ログインした端末のままタイムラインに流して確かめる。`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`のDocuments/DebugInjectにファイルを置き、起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://inject/<home|local|federated|notifications|announcements>?file=<ファイル名>'`を送ると、ストリーミングの新着と同じ経路で流す。ホーム、ローカル、連合は`Status`の配列、通知は`Notification`の配列、サーバーのお知らせは`Announcement`の配列で書く。お知らせのシートは`scia://announcements`で開く。開くとサーバーから読み直して流したお知らせが消えるので、開いてから流す。雛形は`Tools/inject/`にあり、実サーバーの`api/v1/statuses/<id>`の応答をそのまま`status`に入れてもよい。IDはタイムラインの一番新しいものより大きくし、流すたびに変える（同じIDは流れない）。ホームの投稿のIDは、Mastodonと同じく今のミリ秒の時刻を16ビット左へずらして作る。大きすぎるIDにすると、補完がそれより新しい投稿しか読まなくなる。流した投稿や通知はサーバーの既読位置に使わず、通知は補完の基準にも使わない。起動し直すと消える。読めないJSONは流さず、errorのログに残す
- ステータスバーの通知は、`scia-debug://dummy/notifications`で、通知のタイムラインに入れずに続けざまに流す。`scia-debug://ticker-loop/on`にすると、出る、出ている、消えるを1件ずつ繰り返し、`scia-debug://ticker-loop/off`で止める。デバッグメニューの「ステータスバーの通知」の「出し続ける」と同じ。動きは見た目ではなく数値で確かめる。`xcrun simctl spawn '<使う端末>' defaults write net.mizle.scia debug.statusBarTickerTrace -bool true`にすると、背景を広げたり縮めたりしている間の毎コマ、描画中の背景の枠と中身の位置と濃さを、`statusBarTickerTrace`のdebugレベルのログに書く
- 部品の状態ごとの見た目（失敗の表示など）は、失敗を起こさずに、デバッグメニューの「部品カタログ」で並べて見る。agentは起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://catalog/<部品>'`で開く。部品は`App/Sources/Debug/Catalog/ComponentCatalog.swift`の`CatalogComponent`にあり、状態は同じフォルダーの部品ごとのファイルに並べる
- 部品の見た目を足したり変えたりしたら、次に当てはまる状態をカタログに足すか直す。状態を足した、消した、文言を変えたときも合わせる
  - 実物で出すのに手間や副作用がある状態（サーバーの失敗、アップロードの途中、ログインし直し、ストリーミングの切断など）
  - 文言や数の長さで崩れうる状態（長い名前、上限超え、件数）
  - ほかの表示と重なる組み合わせ
- 状態が1つしかないか実物ですぐ出せる見た目、動きや間合い（アニメーション、ジェスチャー、スクロール位置）、画面をまたぐ流れは、カタログに載せない。動きはチューニングと録画で確かめる
- カタログは状態を直接渡し、置き場所も実物をまねたものなので、その状態にたどり着くかと、置かれた場所での見え方（ほかの表示との重なり、安全領域、キーボード）は確かめられない。ふだん通る流れは実物で撮り、失敗の流れも`scia-debug://status/502`などで実物で一度は通す。カタログでは、実物で出しにくい状態と、文言や長さの違いを見比べる
- 部品の見た目を変えた作業の報告には、カタログに足した状態か載せない理由と、どの状態を実物で見て、どの状態をカタログだけで見たかを書く
- 「投稿の見た目」の項目や見本、投稿の行の描き方を変えたら、すべての項目と選択肢を変える前と後に並べた画像を作って、全部見る。`TEST_RUNNER_SCIA_APPEARANCE_SHEETS=1 make test ONLY='SciaTests/AppearanceSheets'`で、`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`のtmp/AppearanceSheetsに書く。示す帯（赤）が変わった部分と合っているか、変えて崩れないかを確かめる。いくつかをつまんで見るだけでは、ずれに気づけない
- クラッシュした投稿の隔離（docs/crash-quarantine.md）の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://crash/next-row?kind=<abort|trap|exception>'`のあと、タブを移るなどで投稿の行を組み立てさせて落とし、`xcrun simctl launch`で起動し直す。`scia-debug://crash/now?kind=<種類>`は行と関係なくすぐ落ち、隔離されないことを確かめるのに使う。送る内容の画面の状態は`scia-debug://catalog/crash-report`で見る
- トークンが無効になったときの表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unauthorized'`で、以後のREST APIに401を返させる。資格情報は消えず、起動し直すと戻る
- 読めなかった投稿や通知の行の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unreadable'`で、以後のホームと通知の応答の3件に1件を読めない形に壊して読み込み直す。起動し直すと戻る
- サーバーやプロキシの障害の表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://status/502'`のように、以後のREST APIにそのステータスのHTMLのエラーページを返させて読み込み直す。`?retry-after=<秒>`を付けると`Retry-After`ヘッダーも返し、429や503で自動の通信を止めて明けたら読み込み直すところを確かめられる。`&target=<経路>`を付けると、REST API（`api`、省略時）のほかの経路にも返させる。経路は`media-proxy`（サーバーが中継する画像）、`files`（そのほかの画像やファイル、リンク先のページ）、`x`（fxtwitter）、`streaming`（つなぐときの応答を断る。開いている接続も切る）、`all`。`scia-debug://status/ok`か起動し直すと戻る
- サーバーにない機能を止める確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unsupported/markers'`のように、以後その機能のAPIに404を返させて読み込み直す。機能は`markers`、`preferences`、`instanceV2`、`multipleStatuses`、`multipleAccounts`、`groupedNotifications`（通知のv2。v1で読む）、`notificationFilter`（保留中の通知）。起動し直すと戻る
- ストリーミングにつながらないときの表示とポーリングの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://streaming/offline'`で、RESTは通したままストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す
- サーバーがホームを作り直している最中の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://regenerating/on'`で、以後のホームの応答を中身はそのままステータスだけ206にする。補完は`scia-debug://streaming/offline`と`online`でつなぎ直して起こす。`scia-debug://regenerating/off`か起動し直すと戻る
- 送る前に縮める流れの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://media-limits?image-size=1000000&video-size=3000000'`のように、投稿欄が使うサーバーのメディアの上限を、指定した項目だけ差し替える。項目は`image-size`・`video-size`（バイト）、`image-matrix`・`video-matrix`（画素数）、`video-frame-rate`。下書きのない状態で投稿欄を開いたときから効くので、下書きがあるときは起動し直してから送る。`scia-debug://media-limits/server`か起動し直すと戻る
- チップの列の動き（画面を移る途中、引っぱる途中、ビューアの開閉）の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://notice/progress'`で、出たままの「処理中」のチップを、進み具合を少しずつ進めながら60秒出す。アプリ全体のものなので、どの画面にも出る。`?seconds=<秒>`で長さを、`?title=<パーセントエンコードした文言>`で文言を変える。`scia-debug://notice/transient?title=<パーセントエンコードした文言>`で、数秒で消えるチップを出す（`&seconds=<秒>`で消えるまでの長さを変える）。2行に折り返す長い文言の出入り、差し替え、スワイプしてしまう操作を確かめるのに使う
- ダウンロード中のアプリ内通知の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://download/slow'`で、以後の共有や保存のためのダウンロードを、進み具合を少しずつ進めながら10秒遅らせる。端末の中のファイルのダミー投稿の動画でも使える。`?seconds=<秒>`で時間を変え、`scia-debug://download/normal`か起動し直すと戻る
- 投稿のメニューを開いている間にユーザーのアイコンが届くところの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://menu-icons/slow'`で、以後のメニューで、まだ読んでいないユーザーのアイコンを3秒遅らせてから読む。一度読んだ画像は起動し直しても端末に残るため、遅らせないと開いた時点で読み終わっている。読み込み済みの人は遅れないので、起動し直してから開く。デバッグメニューの「障害を起こす」の「メニューのアイコンを3秒遅らせる」でも切り替えられる。`?seconds=<秒>`で時間を変え、`scia-debug://menu-icons/normal`か起動し直すと戻る
- プロフィールを開くのを待つ間の確認（押し直す、タブを移る、「取得中」のチップ）には、`xcrun simctl openurl '<使う端末>' 'scia-debug://lookup/slow'`で、以後のプロフィールを開く操作と、ユーザーのメニューのメンションとハンドルのコピーで、相手を探すのを3秒遅らせる。`?seconds=<秒>`で時間を変え、`scia-debug://lookup/normal`か起動し直すと戻る
- 投稿ボタンを押してからメディアの準備を待つ間の確認（待つのをやめる、畳む、待つ間の失敗）には、`xcrun simctl openurl '<使う端末>' 'scia-debug://upload/slow'`で、以後の投稿欄のメディアのアップロードを5秒遅らせる。`?seconds=<秒>`で時間を変え、`scia-debug://upload/normal`か起動し直すと戻る
- 自動翻訳は、シミュレーターでは言語が`unsupported`になるので、`scia-debug://translation/fake`で本文を2回つないだダミーの訳文に替えて確かめる。`?delay=<ミリ秒>`で1段落にかける時間を変える（既定は70）。設定の「自動翻訳」にもダミーの言語が並ぶ。`scia-debug://translation/system`か起動し直すと戻る。訳す言語は`scia-debug://translation/languages?set=en,ko`で置き換える。流れの速いタブでは新着で投稿が流れるので、動きは`scia-debug://dummy-session`のホームに`language`が`en`の投稿を`inject`して撮る。置き換えの動きは、チューニングパネルの「自動翻訳の置き換え」を開くか、`scia-debug://catalog/translation-transition`で、繰り返し見られる
- 設定のストレージの画面が測る置き場所の確認には、`scia-debug://storage-probe`で、画面と同じ内訳と、置き場所ごとにアプリから読めるか（読めないときのエラー）を、アプリのDocuments/AgentDump/storage.txtに書き出す。実機ではアプリ内のSafariのデータ（SystemData）をアプリから読めず、シミュレーターでは読めるので、実機の値は検証用の実機で`xcrun devicectl device process launch --payload-url`で送り、`xcrun devicectl device copy from`で取り出して読む。アプリ内のSafariのデータを溜めるには、`scia-debug://browser?url=<パーセントエンコードしたURL>`でアプリ内のSafariでhttpかhttpsのURLを開く
- 「フォロー中のハッシュタグ」の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://tags/follow?name=<名前>'`でハッシュタグをフォローし、「フォロー中のハッシュタグ」に出す。`scia-debug://tags/unfollow?name=<名前>`で外す。サーバーのフォローを書き換え、フォローしたハッシュタグの投稿はホームにも流れるので、確かめ終えたら外す。ハッシュタグのタブは、フォローと関係なく、ハッシュタグのタイムラインの右上の「タブ」で足す
- リストのタブの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://lists/create?title=<パーセントエンコードした名前>'`でリストを作り、読み直して並びに無効で足す。`scia-debug://lists/delete?id=<ID>`で消す。どちらもサーバーのリストを書き換えるので、確かめ終えたら消す。並びのスイッチはシミュレーターのツールのタップで切り替わらないことがあるので、有効にするときは、アプリを終了してから`xcrun simctl spawn '<使う端末>' defaults write "$(xcrun simctl get_app_container '<使う端末>' net.mizle.scia data)/Library/Preferences/net.mizle.scia" 'account.<ハンドル>/tabLayout' -array <並びの項目>...`で書く。`simctl spawn`の`defaults write net.mizle.scia`はアプリのコンテナの外に書くため、アプリに届かない
- プロフィール画面の確認には、`xcrun simctl openurl '<使う端末>' 'scia://profile/<user@domain>'`でホームのタブにプロフィールを開く。アプリが起動していなくても開く。フォローとフォローの解除は、@Bot_testing@stellaria.networkで確かめる
- 指で操作できない検証用の実機でスクロールの重さを測るときは、`xcrun devicectl device process launch --device <UDID> --payload-url 'scia-debug://autoscroll?distance=<pt>&speed=<pt/秒>' <bundle id>`で、選んでいるタブのタイムラインを一定の速さで動かす。distanceを負にすると上へ戻す。慣性のない一定の速さなので、指で流したときとは動きが違う。条件をそろえて比べるためのもの。動かしている間の落ちたフレームは、指のスクロールと同じ仕組みで数え、アプリのDocuments/DebugAutoscroll.logに1行ずつ書き足すので、`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/DebugAutoscroll.log`で取り出して読む。xctraceの`--attach`は実機では使えず、`--all-processes`では画面の描画を拾えなかった。設定を変えて測り比べるときは、`--payload-url 'scia-debug://appearance?json=<パーセントエンコードしたJSON>'`で、「投稿の見た目」の選ぶ項目のうちJSONに書いたものだけを上書きする（例は`{"showsActionBar":false}`）
- 描画性能: スクロール時のhitchは`xcrun xctrace record --template 'Animation Hitches'`や`XCTOSSignpostMetric.scrollDecelerationMetric`で測る。シミュレーターの値は参考値で、最終確認は実機で行う
- 見た目: 実データに近いfixtureを使い、スクリーンショットで確認する
- 好みで決まる値は、ハードコードで決め打ちしない。余白や文字の大きさのような投稿の見た目の値は、設定の「投稿の見た目」（`AppearanceCatalog`）に項目を足す。アニメーションの時間や新着をまとめて挿入する間隔のような、動きや間合いの値は、`TuningCatalog`に項目を足してデバッグ用のチューニングパネルから調整できるようにする。足した項目は`sections`にも並べる（入れ忘れると、パネルに出ず、`defaults write`で入れた値も読まれない。`make lint`の`tuning_item_not_in_sections`で止める）。パネルはデバッグメニューから開くが、値はデバッグメニューを出していないReleaseでも`TuningStore`から読むので、SciaCoreのモデルには、どのUIも`TuningStore`を作って渡す。どちらも、ユーザーに選んでもらう
- フレームが落ちたスクロールでは、落ちたフレームに使った処理の時間（行の組み立て、行の大きさの計算、並べ直しなど）を、`frameWork`のnoticeのログに1行で残し、アプリのDocuments/FrameWork.jsonに起動をまたいで足し上げる。直す場所を選ぶときは、まずこのファイルで合計の長い処理を見る。測るのは`FrameWork.measure`で囲んだ処理だけなので、`measured`が`hitchTime`よりずっと小さければ、測っていない処理が重い。そのときは`FrameWork.measure`で囲む場所を足すか、Time Profilerで測る
- デバッグメニューは、デバッグ版では常に出す。Releaseでは、設定の「情報」の「ビルド」の行を7回タップするとオンになり（同じ操作でオフに戻る）、チューニング、部品カタログ、違和感レポート、当たり判定の表示、HDRの余地の表示だけを出す。通信や既読位置を変える検証の項目と`scia-debug://`は、DEBUGのビルドだけに入れる
- 違和感レポートは、デバッグメニューから開く。シェイクで開くのはデバッグ版だけ。ユーザーが残した違和感レポートは、アプリのDocuments/DiscomfortReportsにJSONで保存される。シミュレーターでは`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`で場所を調べられる。状態を追いたい画面は`AppDependencies.stateDumps`に状態ダンプを登録し、調査に必要なイベントはinfo以上のレベルで`SciaLog`に出す（debugレベルはレポートに残らない）

## テスト

- テストはSwift Testing（`import Testing`）で書く
- APIレスポンスのfixtureは`Packages/SciaCore/Tests/SciaCoreTests/Fixtures/`に置く。実サーバーのレスポンスを使う場合は、個人を特定できる情報を置き換える
- バグ修正では、先に失敗するテストを書いてから直す
- テストで作る一時ファイルと設定の保存先（`UserDefaults(suiteName:)`）は、`SciaTesting`の`TestScratch`で作り、テストかスイートに`.scratch`を付ける。テストの終わりと次に走らせたときに消すので、走らせるたびに溜まらない（`make lint`の`test_file_without_scratch`で止める）
- テストは実際の時間や今の時刻に頼らせない（`make lint`の`time_dependent_test`で止める）。時間をおく処理には`SciaTesting`の手で進める`Clock`（`TestClock`）を渡し、アニメーションは層の時計（`LayerClock`）、毎フレーム進める動きは手で送るコマ（`ManualFrameSource`）で進める。ほかの処理は門（`Gate`）か条件（`waitUntil`）で待ち（`Task.yield`で譲って待たない。`make lint`の`yield_based_waiting`で止める）、日時は決まった値で作る。止めたあとに何も起きないことは、時間を待たずに、走り終えていない処理の数や予約が残っていないことで確かめる
- 手で進める`Clock`（`TestClock`）を進めるときは、`clock.advance(afterSleeping: 待ちの長さ)`で起こしたい待ちを長さで指す。ほかの条件と一緒に待つときは`sleeperCount(remaining:)`を使う。待ちの数だけを見ると、同じ時計を使う別の待ちで揃ったと読み、眠る前の待ちを起こせずに固まるため（`make lint`の`advance_after_sleeper_count`で止める）
- テストで裏に回った状態を作るときは、`whileInBackground`で囲む。裏に回った通知（`didEnterBackgroundNotification`）を投げたままにすると、UIKitがSwiftUIのスプリングで動かす`UIView.animate`を戻った通知が来るまで止め、同じプロセスであとに走るテストの動きが終わらなくなるため（`make lint`の`background_notification_in_test`で止める）
- `waitUntil`は条件を間をおいて確かめるので、増えていく件数を`==`で待つと、確かめる間に飛び越えて固まる。件数は`>=`で待ってから`#expect`で確かめる（`make lint`の`exact_count_wait`で止める）
- `TimelineStore`のテストは、`TimelineStoreTester`を通し、操作を`expectChanges`に起きる変化と一緒に渡して、状態を丸ごと比べる。確かめたい値だけを見ると、書いていない変化を見逃すため（テストで直接作ったり持ったりするのは`make lint`の`timeline_store_without_tester`で止める）。状態を足すときは、ストアのプロパティではなく`TimelineStore.State`に足す。ストアに直接持つと、比べる対象から漏れるため

## Git

- 作業branchが`claude/epic-feistel-987485`のようにランダムな名前なら、作業を始めたら最初に`git branch -m`で`claude/fix-profile-open-race`のような名前へrenameする。`claude/`は残し、その後ろを種別と中身の分かる名前にする。ランダムな名前のままだと、どのbranchに何が入っているかが名前から分からず、扱いにくいため
- commit messageはConventional Commitsで書く。将来git-cliffでリリースノートを自動生成し、`feat:`、`fix:`、`perf:`だけを使う人向けの変更として載せる前提で種別を選ぶ
- `feat:`は使う人に見える機能の追加、`fix:`は使う人が遭遇する不具合の修正、`perf:`は使う人が体感する性能の改善に使う
- 開発のための変更（チューニングパネル、違和感レポート、検証ハーネス、ビルドやlintの設定など）を`feat`・`fix`・`perf`で書くときは、`feat(dev):`、`fix(dev):`のようにdev scopeを付けてリリースノートから外す
- 使う人向けの変更と開発のための変更は別のcommitに分ける
- pushはユーザーが行う。agentはcommitまでで止め、pushやpush承認の依頼はしない
- mainへは、ユーザーが`/merge-to-main`で起動したときだけ、`.claude/skills/merge-to-main`の手順で入れる（agentからは起動しない。共通の`tidy-ff-merge`は、`make check`と`make test`を通さないので使わない）。`Tools/merge-queue.sh`が、どのスレッドからでも1つずつ、branchをmainへrebaseし、そのworktreeで`make check`と`make test`を通してから、fast-forwardで入れる。通したあとにファイルを変えたり、rebaseで中身が変わったりしたら、通し直す。`make hooks`のhookは、`make check`と`make test`の両方が通っていない中身のcommitと、中身が新しくなるmerge commitをmainに入れず、作業ツリーに触る前に止める
- worktreeの中では、fixup commitを作ることも、`rebase --autosquash`で元のcommitへまとめることも、確認なしで行ってよい。後ろに載ったユーザーのcommitのhashが作り直されても構わない
