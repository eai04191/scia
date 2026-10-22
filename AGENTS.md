# AGENTS.md

SciaはストリーミングAPIでタイムラインが流れる、手触りの良いiOS向けMastodonクライアントです。将来はmacOSにも対応します。何を作り、何を作らないかは[docs/vision.md](docs/vision.md)、作業の単位と順序は[docs/roadmap.md](docs/roadmap.md)を参照してください。

## 構成

- `project.yml`: XcodeGenの定義。`Scia.xcodeproj`と`App/Info.plist`は生成物なのでコミットせず、直接編集しない。ターゲットや設定の変更は`project.yml`で行う
- `Config/Local.xcconfig`: 署名のチーム（`DEVELOPMENT_TEAM = <チームID>`）など、人ごとに違うビルド設定を書く。コミットしないので、worktreeを作ったら元のcheckoutからコピーする。なくてもシミュレーター向けにはビルドできる
- `Packages/SciaCore`: UIに依存しないロジック（モデル、APIクライアント、ストリーミング、タイムラインの状態管理）。iOSとmacOSで共有するため、UIKit／AppKit／SwiftUIをimportしない
- `App/Sources`: iOSアプリ（UIKitライフサイクル）

## 文書の使い分け

- `docs/vision.md`: 何を作り、何を作らないかと、設計の判断の基準。作業が終わっても残す考え方を書く
- `docs/roadmap.md`: 作業の単位と順序。1項目1行で、何をするかだけを書く。設計の判断や、作業を進めるための細かい合意・状態・調べて分かったことは書かない
- 作業を別のthreadへ引き継ぐためのメモ（合意した細部、進み具合、検証の道具など）は、元のcheckoutの`.handoff/`に置く。`.git/info/exclude`で除いてあるのでcommitされない。worktreeは作業が終わると消えるため、worktreeの中には置かない。作業が終わったら消す

## コマンド

- `make generate`: Xcodeプロジェクトを生成する
- `make lint`: SwiftLintで強制アンラップ、`try!`、IUOを検出する（`brew install swiftlint`が必要）
- `make test-core`: SciaCoreのテスト（macOS上、シミュレーター不要）
- `make build`: シミュレーター向けにビルドする
- `make test SIM='<使う端末>'`: シミュレーターでテストする。先に端末のハードウェアキーボードをつなぐ。通ると、確かめた作業ツリーの中身を覚える
- `make check`: 変更を報告する前に必ず通す。通ると、確かめた作業ツリーの中身（commitしていない変更も含む）を覚える
- `make hooks`: ローカルのmainを、`make check`と`make test`の両方が通った中身のcommitにしか動かさないhookを入れる。checkoutごとに1回で、worktreeにも効く。通った中身との違いがMarkdown（`*.md`）だけなら、走らせ直さずに通ったものとして扱う

## シミュレーター

- 動作確認とテストには、`Scia 1`、`Scia 2`、`Scia 3`、`Scia 4`のどれかのシミュレーターを使う。どれもログイン済みの端末の複製で、ログイン情報が端末のKeychainに残っているため、ログインし直さずに済む。複数のスレッドが並行して同じ端末を取り合わないよう、端末を分けている
- どの端末を使うかの指示がなければ、ユーザーに聞く。勝手に選ばない
- シミュレーターのツールでは、決まった端末を毎回`device`で指定する。省略すると、他のスレッドが使っている端末を操作してしまうことがある
- 並行して作業するスレッドは、worktreeも分ける。`make build`・`make test`はworktree直下の`DerivedData`、`make test-core`は`Packages/SciaCore/.build`を使うため、同じworktreeで同時に走らせると、ロック待ちで失敗したり成果物を上書きし合ったりする
- 4台は同じアカウントでログインしているため、サーバー上の状態は共有される。読んだ位置は`api/v1/markers`でサーバーに保存され、起動時に読み込まれるので、別のスレッドがスクロールすると次の起動位置が変わる。投稿やブーストも、ストリーミングで他の端末に流れ込む。起動時の位置や新着の挙動を確かめるときは、他のスレッドの操作で結果が乱れていないか疑う
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- 画面は`Tools/sim.sh dump '<使う端末>'`で文字として読む。アプリの中でアニメーションとスクロールの慣性が止まるのを待ってから（多くは1秒ほど）、要素の名前と中心の座標（タップと同じポイント）、タイムラインの`contentOffset.y`などの状態を出す。初回は、アプリに要素を作らせる設定を端末に入れ、起動し直しを求める。この設定でアプリが少し重くなるので、hitchを測るときは`xcrun simctl spawn '<使う端末>' defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled`で外す
- 見た目を確かめるときは、シミュレーターのツールの`screenshot`ではなく`Tools/sim.sh shot '<使う端末>'`で撮る。画面が止まるのを待ってから、端末のポイント幅に縮小したJPEGを出すので、画像の座標がそのままタップの座標になり、1枚のトークンも約1/5になる。`--crop x,y,幅,高さ`で一部を切り出し、`--full <ファイル>`でユーザーに送る原寸のPNGも残す。原寸は自分では読まない
- よく使う画面は、タップでたどらず`xcrun simctl openurl '<使う端末>' '<URL>'`で開く。`scia-debug://reset`（重ねた画面を閉じてホームに戻す）、`scia-debug://tab/<home|local|federated|notifications>`、`scia-debug://settings`、`scia-debug://tuning`、`scia-debug://viewer?index=<n>`（選んでいるタブで一番上に見えている画像付きの投稿を、n番目の添付ファイルで開く）
- `xcrun simctl openurl '<使う端末>' 'scia-debug://dummy-session'`で、通信しないダミーの投稿と通知でホームと通知の画面に入れる。ログインしていない端末（機種ごとに作る一時的な端末など）でも、ログイン済みの端末でも入れる。ログイン画面のデバッグ用のボタン「ダミーのデータで入る」でも入れる。ログイン済みの端末では、アカウントのメニューにダミーのアカウントが並び、本物のアカウントを選ぶと戻る。Keychainには保存しないので、起動し直すと保存してあるアカウントかログイン画面に戻る。投稿への操作はサーバーに届かず失敗する。新しい端末では、最初にURLを送ったときに「“Scia”で開きますか？」が出るので、一度「開く」を押す必要がある
- URLを送ったあとや操作のあとに`sleep`しない。`dump`と`shot`が画面が止まるまで待つので、続けて行うコマンドは1つのBashの呼び出しにまとめる（例: `xcrun simctl openurl '<使う端末>' 'scia-debug://reset' && Tools/sim.sh dump '<使う端末>'`）
- タップやスワイプのあとは、dumpで結果を確かめてから次へ進む。思った画面でなければ、同じ座標を打ち直さず、dumpから座標を取り直す
- 画像の読み込みのように、動きのないまま中身が後から入る表示は、止まっていても終わっていない。目的の要素が出るまでdumpし直す。ダミー投稿の画像は、流してから1〜2秒で入る
- 写真のピッカーは別のプロセスが描くので、`sim.sh`はその表示を待たない。アプリを起動して最初に開いたときだけ、表示まで数秒かかる。撮った画像にピッカーが写っていなければ、dumpで`mediaPicker: shown`を確かめて、数秒後に撮り直す
- 投稿欄の本文は、シミュレーターのツールの`text`やクリップボードで入らないことがある。`xcrun simctl openurl '<使う端末>' 'scia-debug://compose?text=<パーセントエンコードした本文>'`で、書き始めて本文を置き換える。`&media=<枚数>`を付けるか`text`の代わりに渡すと、番号を描いた色違いの画像（1枚目から赤、青、オレンジ、紫）を添付に足す。ペーストと同じ経路でサーバーに送る。ピッカーは、ピッカーそのものを確かめるときだけ使う
- 自分のプロフィールの編集は、`xcrun simctl openurl '<使う端末>' 'scia-debug://profile-edit'`で開く。日本語のキーボードでは半角の`:`や`@`を打てないので、補完を確かめるときは、`?note=<パーセントエンコードした本文>`で自己紹介を、`?field=<パーセントエンコードした本文>`で足す補足情報の内容を、補完したい語（`@agent_testin`や`:chigau_0`など）にして開く。打ったときと同じく、末尾の語の補完が出る
- 一覧の一番上にいると、新着で行が下へずれ、dumpで読んだ座標が古くなる。一覧の行をタップする前に`scia-debug://arrivals/hold`を送ると、ホームと通知のタブは新着を挿入せずに溜める。終わったら`scia-debug://arrivals/release`で、溜まった新着をまとめて挿入する。ストリーミングはつないだままなので、`streaming/offline`と違って、切断の表示やポーリングで一覧が動かない。再接続などで新着を読む補完も、解くまで見送る。投稿の編集や削除と、保留を送る前に始まっていた補完の結果は、すぐ反映される
- ハードウェアキーボードがつながった扱いだと、ソフトウェアキーボードが出ない。キーボードが出た状態を確かめるときは、`make sim-keyboard SIM='<使う端末>'`でハードウェアキーボードを外す。フォーカス済みの入力欄にも出るが、出るまで少しかかるので、直後のスクリーンショットで判断しない。`KEYBOARD=hardware`を付けるとつなぎ直す

## 設計原則

- ロジックはできるだけSciaCoreに置き、`swift test`で検証できる形にする。アプリ側はSciaCoreの状態を描画するだけの薄い層に保つ
- タイムラインはUICollectionViewとdiffable data sourceで組む。スクロール位置を細かく制御する必要があるため、SwiftUIのListやScrollViewにはしない
- 独自のアニメーションやジェスチャーを足す前に、UIKit標準の部品と挙動で実現できないか検討する
- 画面の骨格、スクロール位置の制御、入力（入力欄、変換、キー操作、フォーカス）、ジェスチャーはUIKitで作る。中に入力もスクロール位置の精密な制御も持たない表示の部品は、SwiftUIで作れないかを先に考え、UIKitの画面に`UIHostingController`で載せる。Liquid Glassの組み方（`glassEffect`、`ConcentricRectangle`、`.containerShape`）をそのまま使えるため。補完の候補の一覧では、UIKitの`containerConcentric`がスクロールに追従しなかったが、SwiftUIでは追従した
- UIKitで作った部品でLiquid Glassの不都合が出たら、SwiftUIへの置き換えを候補に入れる。UIKitとSwiftUIの境目では、`UIViewRepresentable`の中身が大きさの希望を変え続けて並べ直しが止まらなくなることがあるので、包む部品は`sizeThatFits`で大きさを決める
- Mastodon APIの仕様は推測せず、公式ドキュメント（https://docs.joinmastodon.org/ ）で確認する。サーバー実装による差異（glitch-soc、Fedibird、GoToSocialなど）は、必要になった時点で個別に対応してテストに残す
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 文言

- 使う人に見える文言では、対象が画像だけなら「画像」、動画・GIF・音声を含むなら「メディア」と書く。代替テキストや閲覧注意のように種類を問わず付くものを、「画像」と書かない
- ユーザーの`acct`（`@user@domain`）は、使う人に見える文言では、Mastodonのwebに倣って「ハンドル」と書く。「ユーザー名」や「acct」と書かない
- 投稿がサーバーのフィルターに該当することは、「当たる」ではなく「一致する」と書く。使う人に見える文言だけでなく、コメント、テストの説明、カタログの見出しも揃える。残しておくと、あとの作業がその言い方に引きずられるため

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、一覧の上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- 一覧の行を足す・消す・描き直す経路を足したら、[docs/vision.md](docs/vision.md)の「一覧の動き」のどれに当たるかを決め、`setEntries`の`animatesRemoval`などで渡す。使う人の操作で消えるのに動かない、操作によらない変化で読んでいる行が動く、のどちらも起こさないよう、動くかどうかをテストに残す
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中にスワイプする、閉じた直後に別の画像をタップする、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- 動きの録画: `xcrun simctl spawn '<使う端末>' defaults write net.mizle.scia tuning.<項目のid> -float <値>`でチューニングの値（閉じる時間など）を一時的に伸ばし、`xcrun simctl io '<使う端末>' recordVideo --force <ファイル>`をバックグラウンドで起動して録画し（`pkill -INT -f "recordVideo --force <ファイル>"`で止める。ファイルで絞らないと、他のスレッドの録画まで止めてしまう）、ffmpegの`fps=30,crop=...,tile=...`でコマを並べて見る。見たい部分（バーの付近など）を切り出して連続したコマで比べると、1コマだけの切り替わりにも気づける。確認が終わったら`defaults delete`で必ず戻す
- シミュレーターのツールの`touch_path`は、同じ座標の点を動きとして送らない。最後に同じ点を並べて指を止めた形にしても、離した瞬間の速さが残って慣性で流れる。位置を決めたいドラッグには、終点で細かく揺らして速さを0にする`Tools/sim.sh drag <x1> <y1> <x2> <y2>`の点の並びを渡す。最初の20〜80ptはスクロールが始まるまでの遊びに吸われるので、動かしたあとに`contentOffset.y`を測って足りない分を足す。ページめくりや払って閉じる操作は、速さで決まるので`swipe`で行う
- タップが効かないなど、どのビューが触れたものを受けているか分からないときは、lldbで実行中のアプリにつなぎ（`lldb -p <pid> --batch -s <コマンドのファイル>`）、`expr -l swift -O -- `でウィンドウの`hitTest`やビュー階層（`recursiveDescription`）を調べる
- ビューアの確認には、デバッグメニューのダミー投稿（形の違う4枚、縦長1枚、画面より小さい3枚、透過画像1枚、動画とGIF、音声付きの長い動画）を使う。通信せずに一覧の一番上に出せる（起動し直すと消える）。動画とGIFは初回だけ端末で書き出すため、少し遅れて流れる
- agentはメニューを開かず、起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://dummy/<種類>'`でダミー投稿を流す。種類は`arrivals`（新着10件）、`images`（4枚）、`tall`（縦長1枚）、`small`（画面より小さい3枚。3枚目は元の大きさを付けない）、`transparent`（透過画像1枚）、`video`（動画とGIF）、`long-video`（毎秒音が鳴り、経過した秒数を描いた90秒の動画）、`link-card`と`link-card-image`（リンク先だけのカードで流し、5秒後に通信せずに画像のないカード、画像付きのカードを届ける。届いたときの動きを、動きの途中の操作と合わせて確かめる）、`link-card-sensitive`（`link-card-image`を閲覧注意の投稿で流す）、`x-post`（Xの投稿へのリンクだけのカードで流し、5秒後にfxtwitterに頼まずに、4枚の画像付きのXの投稿を届ける。囲みはチューニングの「Xの投稿をfxtwitterから読んで出す（試作）」がオンのときだけ出る）、`filtered`（サーバーのフィルターに一致した4件を流す。警告、警告と注意書き、添付ファイルのぼかし、隠すの4つで、隠す1件は一覧に出ない）、`animated-emojis`（動くカスタム絵文字を8個ずつ入れた40件。絵文字はmisskey.ioの実物なので通信が要る）。アプリが起動していないときに送ると、アプリは起動するがダミーは流れない
- 実データにない投稿や通知の見え方は、APIの応答と同じ形のJSONを、ログインした端末のまま一覧に流して確かめる。`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`のDocuments/DebugInjectにファイルを置き、起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://inject/<home|local|federated|notifications>?file=<ファイル名>'`を送ると、ストリーミングの新着と同じ経路で流す。ホーム、ローカル、連合は`Status`の配列、通知は`Notification`の配列で書く。雛形は`Tools/inject/`にあり、実サーバーの`api/v1/statuses/<id>`の応答をそのまま`status`に入れてもよい。IDは一覧の一番新しいものより大きくし、流すたびに変える（同じIDは流れない）。ホームの投稿のIDは、Mastodonと同じく今のミリ秒の時刻を16ビット左へずらして作る。大きすぎるIDにすると、補完がそれより新しい投稿しか読まなくなる。流した投稿や通知はサーバーの既読位置に使わず、通知は補完の基準にも使わない。起動し直すと消える。読めないJSONは流さず、errorのログに残す
- ステータスバーの通知は、`scia-debug://dummy/notifications`で、通知の一覧に入れずに続けざまに流す。`scia-debug://ticker-loop/on`にすると、出る、出ている、消えるを1件ずつ繰り返し、`scia-debug://ticker-loop/off`で止める。デバッグメニューの「ステータスバーの通知を出し続ける」と同じ。動きは見た目ではなく数値で確かめる。`xcrun simctl spawn '<使う端末>' defaults write net.mizle.scia debug.statusBarTickerTrace -bool true`にすると、背景を広げたり縮めたりしている間の毎コマ、描画中の背景の枠と中身の位置と濃さを、`statusBarTickerTrace`のdebugレベルのログに書く
- 部品の状態ごとの見た目（失敗の表示など）は、失敗を起こさずに、デバッグメニューの「部品カタログ」で並べて見る。agentは起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://catalog/<部品>'`で開く。部品は`App/Sources/Debug/Catalog/ComponentCatalog.swift`の`CatalogComponent`にあり、状態は同じフォルダーの部品ごとのファイルに並べる
- 部品の見た目を足したり変えたりしたら、次に当てはまる状態をカタログに足すか直す。状態を足した、消した、文言を変えたときも合わせる
  - 実物で出すのに手間や副作用がある状態（サーバーの失敗、アップロードの途中、ログインし直し、ストリーミングの切断など）
  - 文言や数の長さで崩れうる状態（長い名前、上限超え、件数）
  - ほかの表示と重なる組み合わせ
- 状態が1つしかないか実物ですぐ出せる見た目、動きや間合い（アニメーション、ジェスチャー、スクロール位置）、画面をまたぐ流れは、カタログに載せない。動きはチューニングと録画で確かめる
- カタログは状態を直接渡し、置き場所も実物をまねたものなので、その状態にたどり着くかと、置かれた場所での見え方（ほかの表示との重なり、安全領域、キーボード）は確かめられない。ふだん通る流れは実物で撮り、失敗の流れも`scia-debug://status/502`などで実物で一度は通す。カタログでは、実物で出しにくい状態と、文言や長さの違いを見比べる
- 部品の見た目を変えた作業の報告には、カタログに足した状態か載せない理由と、どの状態を実物で見て、どの状態をカタログだけで見たかを書く
- トークンが無効になったときの表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unauthorized'`で、以後のREST APIに401を返させる。資格情報は消えず、起動し直すと戻る
- 読めなかった投稿や通知の行の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unreadable'`で、以後のホームと通知の応答の3件に1件を読めない形に壊して読み込み直す。起動し直すと戻る
- サーバーやプロキシの障害の表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://status/502'`のように、以後のREST APIにそのステータスのHTMLのエラーページを返させて読み込み直す。`?retry-after=<秒>`を付けると`Retry-After`ヘッダーも返し、429や503で自動の通信を止めて明けたら読み込み直すところを確かめられる。`scia-debug://status/ok`か起動し直すと戻る
- サーバーにない機能を止める確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unsupported/markers'`のように、以後その機能のAPIに404を返させて読み込み直す。機能は`markers`、`preferences`、`instanceV2`、`multipleStatuses`。起動し直すと戻る
- ストリーミングにつながらないときの表示とポーリングの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://streaming/offline'`で、RESTは通したままストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す
- サーバーがホームを作り直している最中の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://regenerating/on'`で、以後のホームの応答を中身はそのままステータスだけ206にする。補完は`scia-debug://streaming/offline`と`online`でつなぎ直して起こす。`scia-debug://regenerating/off`か起動し直すと戻る
- 送る前に縮める流れの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://media-limits?image-size=1000000&video-size=3000000'`のように、投稿欄が使うサーバーのメディアの上限を、指定した項目だけ差し替える。項目は`image-size`・`video-size`（バイト）、`image-matrix`・`video-matrix`（画素数）、`video-frame-rate`。下書きのない状態で投稿欄を開いたときから効くので、下書きがあるときは起動し直してから送る。`scia-debug://media-limits/server`か起動し直すと戻る
- チップの列の動き（画面を移る途中、引っぱる途中、ビューアの開閉）の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://notice/progress'`で、出たままの「処理中」のチップを、進み具合を刻みながら60秒出す。アプリ全体のものなので、どの画面にも出る。`?seconds=<秒>`で長さを変える
- ダウンロード中のアプリ内通知の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://download/slow'`で、以後の共有や保存のためのダウンロードを、進み具合を刻みながら10秒遅らせる。端末の中のファイルのダミー投稿の動画でも使える。`?seconds=<秒>`で時間を変え、`scia-debug://download/normal`か起動し直すと戻る
- プロフィール画面の確認には、`xcrun simctl openurl '<使う端末>' 'scia://profile/<user@domain>'`でホームのタブにプロフィールを開く。アプリが起動していなくても開く。フォローとフォローの解除は、@Bot_testing@stellaria.networkで確かめる
- 描画性能: スクロール時のhitchは`xcrun xctrace record --template 'Animation Hitches'`や`XCTOSSignpostMetric.scrollDecelerationMetric`で測る。シミュレーターの値は参考値で、最終確認は実機で行う
- 見た目: 実データに近いfixtureを使い、スクリーンショットで確認する
- 好みで決まる値（アニメーションの時間、余白、新着をまとめて挿入する間隔など）は、ハードコードで決め打ちせず、`TuningCatalog`に項目を足してデバッグ用のチューニングパネルから調整できるようにし、ユーザーに選んでもらう
- ユーザーがシェイクで残した違和感レポートは、アプリのDocuments/DiscomfortReportsにJSONで保存される。シミュレーターでは`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`で場所を調べられる。状態を追いたい画面は`AppDependencies.stateDumps`に状態ダンプを登録し、調査に必要なイベントはinfo以上のレベルで`SciaLog`に出す（debugレベルはレポートに残らない）

## テスト

- テストはSwift Testing（`import Testing`）で書く
- APIレスポンスのfixtureは`Packages/SciaCore/Tests/SciaCoreTests/Fixtures/`に置く。実サーバーのレスポンスを使う場合は、個人を特定できる情報を置き換える
- バグ修正では、先に失敗するテストを書いてから直す

## Git

- commit messageはConventional Commitsで書く。将来git-cliffでリリースノートを自動生成し、`feat:`、`fix:`、`perf:`だけを使う人向けの変更として載せる前提で種別を選ぶ
- `feat:`は使う人に見える機能の追加、`fix:`は使う人が遭遇する不具合の修正、`perf:`は使う人が体感する性能の改善に使う
- 開発のための変更（チューニングパネル、違和感レポート、検証ハーネス、ビルドやlintの設定など）を`feat`・`fix`・`perf`で書くときは、`feat(dev):`、`fix(dev):`のようにdev scopeを付けてリリースノートから外す
- 使う人向けの変更と開発のための変更は別のcommitに分ける
- pushはユーザーが行う。agentはcommitまでで止め、pushやpush承認の依頼はしない
- mainへは、`.claude/skills/merge-to-main`の手順で（共通の`tidy-ff-merge`は、`make check`と`make test`を通さないので使わない）、branchをmainへrebaseし、そのworktreeで`make check`と`make test`を通してから、fast-forwardで入れる。通したあとにファイルを変えたり、rebaseで中身が変わったりしたら、通し直す。`make hooks`のhookは、`make check`と`make test`の両方が通っていない中身のcommitと、中身が新しくなるmerge commitをmainに入れず、作業ツリーに触る前に止める
- worktreeの中では、fixup commitを作ることも、`rebase --autosquash`で元のcommitへまとめることも、確認なしで行ってよい。後ろに載ったユーザーのcommitのhashが作り直されても構わない
