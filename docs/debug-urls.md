# 検証のためのURL

`scia-debug://`のURLで、実物で出しにくい状態を作って確かめる。DEBUGのビルドだけに入る。URLは`Tools/sim.sh ctl '<使う端末>' openurl '<URL>'`で送る。検証の機能を足したら、ここに足す。

## セッションとアカウント

- `Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://dummy-session'`で、通信しないダミーの投稿と通知でホームと通知の画面に入れる。ログインしていない端末（機種ごとに作る一時的な端末など）でも、ログイン済みの端末でも入れる。ログイン画面のデバッグ用のボタン「ダミーのデータで入る」でも入れる。ログイン済みの端末では、アカウントのメニューにダミーのアカウントが並び、本物のアカウントを選ぶと戻る。Keychainには保存しないので、起動し直すと保存してあるアカウントかログイン画面に戻る。投稿への操作はサーバーに届かず失敗する。新しい端末では、最初にURLを送ったときに「“Scia”で開きますか？」が出るので、一度「開く」を押す必要がある
- 絵文字のリアクション（Fedibirdの拡張、docs/emoji-reaction.md）の実物は、`Scia 4`に保存してあるFedibirdのアカウントで確かめる。`Tools/sim.sh acquire 'Scia 4'`で端末を指定して借り、`Tools/sim.sh ctl 'Scia 4' openurl 'scia-debug://account?acct=<ハンドル>'`で、メニューを触らずに保存してあるアカウントに切り替える。付け外しは、ほかの人に通知が届かないよう、そのアカウントの自分の投稿で試し、確かめたら外す。リアクションの通知は`Tools/inject/notification-emoji-reaction.json`を流して見る

## 入力と新着の保留

- 投稿欄の本文は、シミュレーターのツールの`text`やクリップボードで入らないことがある。`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://compose?text=<パーセントエンコードした本文>'`で、書き始めて本文を置き換える。打ったときと同じく、末尾の語の補完も出る。`scia-debug://compose/close`で、下書きを残してカプセルに戻す。`scia-debug://compose/open`で、下書きを変えずにカプセルを押したときと同じく書き始める。`scia-debug://compose/reply?file=<ファイル名>`で、`inject`と同じ置き場所のファイルにある最初の投稿へ返信を始める。`&media=<枚数>`を付けるか`text`の代わりに渡すと、番号を描いた色違いの画像（1枚目から赤、青、オレンジ、紫）を添付に足す。ペーストと同じ経路でサーバーに送る。`&poll=<パーセントエンコードした選択肢を,で区切る>`を付けるか`text`の代わりに渡すと、投票の欄を出して選択肢を置き換え、フォーカスは本文に残す。選択肢は日本語のキーボードで打つと崩れるので、これで入れる。ピッカーは、ピッカーそのものを確かめるときだけ使う
- 自分のプロフィールの編集は、`Tools/sim.sh ctl '<使う端末>' openurl 'scia://profile-edit'`で開く。日本語のキーボードでは半角の`:`や`@`を打てないので、補完を確かめるときは、`scia-debug://profile-edit`に`?note=<パーセントエンコードした本文>`で自己紹介を、`?field=<パーセントエンコードした本文>`で足す補足情報の内容を、補完したい語（`@agent_testin`や`:chigau_0`など）にして開く。打ったときと同じく、末尾の語の補完が出る
- タイムラインの一番上にいると、新着で行が下へずれ、dumpで読んだ座標が古くなる。タイムラインの行をタップする前に`scia-debug://arrivals/hold`を送ると、ホームと通知のタブは新着を挿入せずに溜める。終わったら`scia-debug://arrivals/release`で、溜まった新着をまとめて挿入する。ストリーミングはつないだままなので、`streaming/offline`と違って、切断の表示やポーリングでタイムラインが動かない。再接続などで新着を読む補完も、解くまで見送る。投稿の編集や削除と、保留を送る前に始まっていた補完の結果は、すぐ反映される
- ハードウェアキーボードがつながった扱いだと、ソフトウェアキーボードが出ない。キーボードが出た状態を確かめるときは、`make sim-keyboard`で、借りている端末のハードウェアキーボードを外す。フォーカス済みの入力欄にも出るが、出るまで少しかかるので、直後のスクリーンショットで判断しない。`KEYBOARD=hardware`を付けるとつなぎ直す

## ダミーの投稿と通知

- ビューアの確認には、デバッグメニューのダミー投稿（形の違う4枚、縦長1枚、画面より小さい3枚、透過画像1枚、動画とGIF、音声付きの長い動画）を使う。通信せずにタイムラインの一番上に出せる（起動し直すと消える）。動画とGIFは初回だけ端末で書き出すため、少し遅れて流れる
- agentはメニューを開かず、起動済みのアプリへ`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://dummy/<種類>'`でダミー投稿を流す。種類は`arrivals`（新着10件）、`images`（4枚）、`tall`（縦長1枚）、`small`（画面より小さい3枚。3枚目は元の大きさを付けない）、`transparent`（透過画像1枚）、`video`（動画とGIF）、`long-video`（経過した秒数を描いた90秒の動画。音声トラックは付くが無音）、`link-card`と`link-card-image`（リンク先だけのカードで流し、5秒後に通信せずに画像のないカード、画像付きのカードを届ける。届いたときの動きを、動きの途中の操作と合わせて確かめる）、`link-card-sensitive`（`link-card-image`を閲覧注意の投稿で流す）、`x-post`（Xの投稿へのリンクだけのカードで流し、5秒後にfxtwitterに頼まずに、4枚の画像付きのXの投稿を届ける。囲みは設定の「表示」の「リンク先の読み込み」で「Xの投稿を展開」がオンのときだけ出る）、`filtered`（サーバーのフィルターに一致した6件を流す。警告、警告と注意書き、2つのフィルターの警告、添付ファイルのぼかし、2つのフィルターのぼかし、隠すの6つで、隠す1件はタイムラインに出ない）、`animated-emojis`（動くカスタム絵文字を8個ずつ入れた40件。絵文字はmisskey.ioの実物なので通信が要る）、`polls`（投票の付いた4件。複数選べない、複数選べる、締め切るまで票数を隠す、締め切った投票。投票と更新は通信せず、1秒待ってから票を足した結果を返す）、`quotes`（引用のある4件。引用元に画像と入れ子の引用、引用元に注意書き、承認待ち、ミュートしている人。引用元もサーバーにないので、囲みを押して開くスレッドは読み込めない）、`reactions`（絵文字のリアクションの付いた4件。1つ、折り返すほど多い、カスタム絵文字とほかのサーバーのカスタム絵文字、数の大きいもの。列はサーバーが絵文字のリアクションに対応しているときだけ出る。投稿はサーバーにないので、付け外しは失敗して戻る。ほかの人のリアクションの数の変化は、`scia-debug://emoji-reaction?name=<パーセントエンコードした絵文字>&count=<数>`で、選んでいるタブで一番上に見えている投稿に、ストリーミングと同じ経路で当てる。`me=1`で自分がしたもの、`count=0`でなくなる）。アプリが起動していないときに送ると、アプリは起動するがダミーは流れない
- 実データにない投稿や通知の見え方は、APIの応答と同じ形のJSONを、ログインした端末のままタイムラインに流して確かめる。`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`のDocuments/DebugInjectにファイルを置き、起動済みのアプリへ`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://inject/<home|local|federated|notifications|announcements>?file=<ファイル名>'`を送ると、ストリーミングの新着と同じ経路で流す。ホーム、ローカル、連合は`Status`の配列、通知は`Notification`の配列、サーバーのお知らせは`Announcement`の配列で書く。お知らせのシートは`scia://announcements`で開く。開くとサーバーから読み直して流したお知らせが消えるので、開いてから流す。雛形は`Tools/inject/`にあり、実サーバーの`api/v1/statuses/<id>`の応答をそのまま`status`に入れてもよい。IDはタイムラインの一番新しいものより大きくし、流すたびに変える（同じIDは流れない）。ホームの投稿のIDは、Mastodonと同じく今のミリ秒の時刻を16ビット左へずらして作る。大きすぎるIDにすると、補完がそれより新しい投稿しか読まなくなる。流した投稿や通知はサーバーの既読位置に使わず、通知は補完の基準にも使わない。起動し直すと消える。読めないJSONは流さず、errorのログに残す
- ステータスバーの通知は、`scia-debug://dummy/notifications`で、通知のタイムラインに入れずに続けざまに流す。`scia-debug://ticker-loop/on`にすると、出る、出ている、消えるを1件ずつ繰り返し、`scia-debug://ticker-loop/off`で止める。デバッグメニューの「ステータスバーの通知」の「出し続ける」と同じ。動きは見た目ではなく数値で確かめる。`Tools/sim.sh ctl '<使う端末>' spawn defaults write net.mizle.scia debug.statusBarTickerTrace -bool true`にすると、背景を広げたり縮めたりしている間の毎コマ、描画中の背景の枠と中身の位置と濃さを、`statusBarTickerTrace`のdebugレベルのログに書く

## 障害と遅延

- クラッシュした投稿の隔離（docs/crash-quarantine.md）の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://crash/next-row?kind=<abort|trap|exception>'`のあと、タブを移るなどで投稿の行を組み立てさせて落とし、`xcrun simctl launch`で起動し直す。`scia-debug://crash/now?kind=<種類>`は行と関係なくすぐ落ち、隔離されないことを確かめるのに使う。送る内容の画面の状態は`scia-debug://catalog/crash-report`で見る
- トークンが無効になったときの表示の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://unauthorized'`で、以後のREST APIに401を返させる。資格情報は消えず、起動し直すと戻る
- 読めなかった投稿や通知の行の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://unreadable'`で、以後のホームと通知の応答の3件に1件を読めない形に壊して読み込み直す。起動し直すと戻る
- サーバーやプロキシの障害の表示の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://status/502'`のように、以後のREST APIにそのステータスのHTMLのエラーページを返させて読み込み直す。`?retry-after=<秒>`を付けると`Retry-After`ヘッダーも返し、429や503で自動の通信を止めて明けたら読み込み直すところを確かめられる。`&target=<経路>`を付けると、REST API（`api`、省略時）のほかの経路にも返させる。経路は`media-proxy`（サーバーが中継する画像）、`files`（そのほかの画像やファイル、リンク先のページ）、`x`（fxtwitter）、`streaming`（つなぐときの応答を断る。開いている接続も切る）、`all`。`scia-debug://status/ok`か起動し直すと戻る
- サーバーにない機能を止める確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://unsupported/markers'`のように、以後その機能のAPIに404を返させて読み込み直す。機能は`markers`、`preferences`、`instanceV2`、`multipleStatuses`、`multipleAccounts`、`groupedNotifications`（通知のv2。v1で読む）、`notificationFilter`（保留中の通知）。起動し直すと戻る
- ストリーミングにつながらないときの表示とポーリングの確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://streaming/offline'`で、RESTは通したままストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す
- サーバーがホームを作り直している最中の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://regenerating/on'`で、以後のホームの応答を中身はそのままステータスだけ206にする。補完は`scia-debug://streaming/offline`と`online`でつなぎ直して起こす。`scia-debug://regenerating/off`か起動し直すと戻る
- 送る前に縮める流れの確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://media-limits?image-size=1000000&video-size=3000000'`のように、投稿欄が使うサーバーのメディアの上限を、指定した項目だけ差し替える。項目は`image-size`・`video-size`（バイト）、`image-matrix`・`video-matrix`（画素数）、`video-frame-rate`。下書きのない状態で投稿欄を開いたときから効くので、下書きがあるときは起動し直してから送る。`scia-debug://media-limits/server`か起動し直すと戻る
- チップの列の動き（画面を移る途中、引っぱる途中、ビューアの開閉）の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://notice/progress'`で、出たままの「処理中」のチップを、進み具合を少しずつ進めながら60秒出す。アプリ全体のものなので、どの画面にも出る。`?seconds=<秒>`で長さを、`?title=<パーセントエンコードした文言>`で文言を変える。`scia-debug://notice/transient?title=<パーセントエンコードした文言>`で、数秒で消えるチップを出す（`&seconds=<秒>`で消えるまでの長さを変える）。2行に折り返す長い文言の出入り、差し替え、スワイプしてしまう操作を確かめるのに使う
- ダウンロード中のアプリ内通知の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://download/slow'`で、以後の共有や保存のためのダウンロードを、進み具合を少しずつ進めながら10秒遅らせる。端末の中のファイルのダミー投稿の動画でも使える。`?seconds=<秒>`で時間を変え、`scia-debug://download/normal`か起動し直すと戻る
- 投稿のメニューを開いている間にユーザーのアイコンが届くところの確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://menu-icons/slow'`で、以後のメニューで、まだ読んでいないユーザーのアイコンを3秒遅らせてから読む。一度読んだ画像は起動し直しても端末に残るため、遅らせないと開いた時点で読み終わっている。読み込み済みの人は遅れないので、起動し直してから開く。デバッグメニューの「障害を起こす」の「メニューのアイコンを3秒遅らせる」でも切り替えられる。`?seconds=<秒>`で時間を変え、`scia-debug://menu-icons/normal`か起動し直すと戻る
- プロフィールを開くのを待つ間の確認（押し直す、タブを移る、「取得中」のチップ）には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://lookup/slow'`で、以後のプロフィールを開く操作と、ユーザーのメニューのメンションとハンドルのコピーで、相手を探すのを3秒遅らせる。`?seconds=<秒>`で時間を変え、`scia-debug://lookup/normal`か起動し直すと戻る
- 投稿ボタンを押してからメディアの準備を待つ間の確認（待つのをやめる、畳む、待つ間の失敗）には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://upload/slow'`で、以後の投稿欄のメディアのアップロードを5秒遅らせる。`?seconds=<秒>`で時間を変え、`scia-debug://upload/normal`か起動し直すと戻る

## 機能ごとの確かめ

- 自動翻訳は、シミュレーターでは言語が`unsupported`になるので、`scia-debug://translation/fake`で本文を2回つないだダミーの訳文に替えて確かめる。`?delay=<ミリ秒>`で1段落にかける時間を変える（既定は70）。設定の「自動翻訳」にもダミーの言語が並ぶ。`scia-debug://translation/system`か起動し直すと戻る。訳す言語は`scia-debug://translation/languages?set=en,ko`で置き換える。流れの速いタブでは新着で投稿が流れるので、動きは`scia-debug://dummy-session`のホームに`language`が`en`の投稿を`inject`して撮る。置き換えの動きは、チューニングパネルの「自動翻訳の置き換え」を開くか、`scia-debug://catalog/translation-transition`で、繰り返し見られる
- 設定のストレージの画面が測る置き場所の確認には、`scia-debug://storage-probe`で、画面と同じ内訳と、置き場所ごとにアプリから読めるか（読めないときのエラー）を、アプリのDocuments/AgentDump/storage.txtに書き出す。実機ではアプリ内のSafariのデータ（SystemData）をアプリから読めず、シミュレーターでは読めるので、実機の値は検証用の実機で`xcrun devicectl device process launch --payload-url`で送り、`xcrun devicectl device copy from`で取り出して読む。アプリ内のSafariのデータを溜めるには、`scia-debug://browser?url=<パーセントエンコードしたURL>`でアプリ内のSafariでhttpかhttpsのURLを開く
- 「フォロー中のハッシュタグ」の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://tags/follow?name=<名前>'`でハッシュタグをフォローし、「フォロー中のハッシュタグ」に出す。`scia-debug://tags/unfollow?name=<名前>`で外す。サーバーのフォローを書き換え、フォローしたハッシュタグの投稿はホームにも流れるので、確かめ終えたら外す。ハッシュタグのタブは、フォローと関係なく、ハッシュタグのタイムラインの右上の「タブ」で足す
- リストのタブの確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://lists/create?title=<パーセントエンコードした名前>'`でリストを作り、読み直して並びに無効で足す。`scia-debug://lists/delete?id=<ID>`で消す。どちらもサーバーのリストを書き換えるので、確かめ終えたら消す。並びのスイッチはシミュレーターのツールのタップで切り替わらないことがあるので、有効にするときは、アプリを終了してから`Tools/sim.sh ctl '<使う端末>' spawn defaults write "$(xcrun simctl get_app_container '<使う端末>' net.mizle.scia data)/Library/Preferences/net.mizle.scia" 'account.<ハンドル>/tabLayout' -array <並びの項目>...`で書く。`Tools/sim.sh ctl '<使う端末>' spawn`の`defaults write net.mizle.scia`はアプリのコンテナの外に書く。アプリは、コンテナの中に同じキーがなければその値を読むが（チューニングやデバッグ用の値）、アプリが一度書いたキー（タブの並びなど）はコンテナの中の値を優先するため、届かない
- プロフィール画面の確認には、`Tools/sim.sh ctl '<使う端末>' openurl 'scia://profile/<user@domain>'`でホームのタブにプロフィールを開く。アプリが起動していなくても開く。フォローとフォローの解除は、@Bot_testing@stellaria.networkで確かめる

## 実機

- 指で操作できない検証用の実機でスクロールの重さを測るときは、`xcrun devicectl device process launch --device <UDID> --payload-url 'scia-debug://autoscroll?distance=<pt>&speed=<pt/秒>' <bundle id>`で、選んでいるタブのタイムラインを一定の速さで動かす。distanceを負にすると上へ戻す。慣性のない一定の速さなので、指で流したときとは動きが違う。条件をそろえて比べるためのもの。動かしている間の落ちたフレームは、指のスクロールと同じ仕組みで数え、アプリのDocuments/DebugAutoscroll.logに1行ずつ書き足すので、`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/DebugAutoscroll.log`で取り出して読む。設定を変えて測り比べるときは、`--payload-url 'scia-debug://appearance?json=<パーセントエンコードしたJSON>'`で、「投稿の見た目」の選ぶ項目のうちJSONに書いたものだけを上書きする（例は`{"showsActionBar":false}`）

## デバッグ版だけの画面

- `scia-debug://viewer?index=<n>`（選んでいるタブで一番上に見えている画像付きの投稿を、n番目の添付ファイルでビューアに開く。代替テキストの全文はビューアの「代替テキスト」から開く）、`scia-debug://profile-edit?crop=<avatar|header>`（ダミーの画像でアイコンかヘッダー画像の切り抜きを開く）、`scia-debug://discomfort-report`（違和感レポート）、`scia-debug://tuning`（チューニング）、`scia-debug://catalog`（部品カタログ）
