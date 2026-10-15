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
- `make test SIM_DESTINATION='platform=iOS Simulator,name=<使う端末>'`: シミュレーターでテストする
- `make check`: 変更を報告する前に必ず通す

## シミュレーター

- 動作確認とテストには、`Scia 1`、`Scia 2`、`Scia 3`のどれかのシミュレーターを使う。どれもログイン済みの端末の複製で、ログイン情報が端末のKeychainに残っているため、ログインし直さずに済む。複数のスレッドが並行して同じ端末を取り合わないよう、端末を分けている
- どの端末を使うかの指示がなければ、ユーザーに聞く。勝手に選ばない
- シミュレーターのツールでは、決まった端末を毎回`device`で指定する。省略すると、他のスレッドが使っている端末を操作してしまうことがある
- 並行して作業するスレッドは、worktreeも分ける。`make build`・`make test`はworktree直下の`DerivedData`、`make test-core`は`Packages/SciaCore/.build`を使うため、同じworktreeで同時に走らせると、ロック待ちで失敗したり成果物を上書きし合ったりする
- 3台は同じアカウントでログインしているため、サーバー上の状態は共有される。読んだ位置は`api/v1/markers`でサーバーに保存され、起動時に読み込まれるので、別のスレッドがスクロールすると次の起動位置が変わる。投稿やブーストも、ストリーミングで他の端末に流れ込む。起動時の位置や新着の挙動を確かめるときは、他のスレッドの操作で結果が乱れていないか疑う
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- ハードウェアキーボードがつながった扱いだと、ソフトウェアキーボードが出ない。キーボードが出た状態を確かめるときは、`make sim-keyboard SIM='<使う端末>'`でハードウェアキーボードを外す。フォーカス済みの入力欄にも出るが、出るまで少しかかるので、直後のスクリーンショットで判断しない。`KEYBOARD=hardware`を付けるとつなぎ直す

## 設計原則

- ロジックはできるだけSciaCoreに置き、`swift test`で検証できる形にする。アプリ側はSciaCoreの状態を描画するだけの薄い層に保つ
- タイムラインはUICollectionViewとdiffable data sourceで組む。スクロール位置を細かく制御する必要があるため、SwiftUIのListやScrollViewにはしない
- 独自のアニメーションやジェスチャーを足す前に、UIKit標準の部品と挙動で実現できないか検討する
- Mastodon APIの仕様は推測せず、公式ドキュメント（https://docs.joinmastodon.org/ ）で確認する。サーバー実装による差異（glitch-soc、Fedibird、GoToSocialなど）は、必要になった時点で個別に対応してテストに残す
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 文言

- 使う人に見える文言では、対象が画像だけなら「画像」、動画・GIF・音声を含むなら「メディア」と書く。代替テキストや閲覧注意のように種類を問わず付くものを、「画像」と書かない

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、一覧の上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中に払う、閉じた直後に別の画像を叩く、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- 動きの録画: `xcrun simctl spawn '<使う端末>' defaults write net.mizle.scia tuning.<項目のid> -float <値>`でチューニングの値（閉じる時間など）を一時的に伸ばし、`xcrun simctl io '<使う端末>' recordVideo --force <ファイル>`をバックグラウンドで起動して録画し（`pkill -INT -f "recordVideo --force <ファイル>"`で止める。ファイルで絞らないと、他のスレッドの録画まで止めてしまう）、ffmpegの`fps=30,crop=...,tile=...`でコマを並べて見る。見たい部分（バーの付近など）を切り出して連続したコマで比べると、1コマだけの切り替わりにも気づける。確認が終わったら`defaults delete`で必ず戻す
- シミュレーターのドラッグは慣性が残り、直後のスクリーンショットと位置がずれる。`touch_path`の最後の数点を小刻みにして指を止めてから離し、スクリーンショットを2回撮って止まったことを確かめてから座標を決める
- タップが効かないなど、どのビューが触れたものを受けているか分からないときは、lldbで実行中のアプリにつなぎ（`lldb -p <pid> --batch -s <コマンドのファイル>`）、`expr -l swift -O -- `でウィンドウの`hitTest`やビュー階層（`recursiveDescription`）を調べる
- ビューアの確認には、デバッグメニューのダミー投稿（形の違う4枚、縦長1枚、透過画像1枚、動画とGIF）を使う。通信せずに一覧の一番上に出せる（起動し直すと消える）。動画とGIFは初回だけ端末で書き出すため、少し遅れて流れる
- agentはメニューを開かず、起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://dummy/<種類>'`でダミー投稿を流す。種類は`arrivals`（新着10件）、`images`（4枚）、`tall`（縦長1枚）、`transparent`（透過画像1枚）、`video`（動画とGIF）。アプリが起動していないときに送ると、アプリは起動するがダミーは流れない
- 部品の状態ごとの見た目（失敗の表示など）は、失敗を起こさずに、デバッグメニューの「部品カタログ」で並べて見る。agentは起動済みのアプリへ`xcrun simctl openurl '<使う端末>' 'scia-debug://catalog/<部品>'`で開く。部品は`App/Sources/Debug/Catalog/ComponentCatalog.swift`の`CatalogComponent`にあり、状態は同じフォルダーの部品ごとのファイルに並べる。状態の見た目を変えたら、そこに状態を足す
- トークンが無効になったときの表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unauthorized'`で、以後のREST APIに401を返させる。資格情報は消えず、起動し直すと戻る
- 読めなかった投稿や通知の行の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unreadable'`で、以後のホームと通知の応答の3件に1件を読めない形に壊して読み込み直す。起動し直すと戻る
- サーバーやプロキシの障害の表示の確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://status/502'`のように、以後のREST APIにそのステータスのHTMLのエラーページを返させて読み込み直す。`?retry-after=<秒>`を付けると`Retry-After`ヘッダーも返し、429や503で自動の通信を止めて明けたら読み込み直すところを確かめられる。`scia-debug://status/ok`か起動し直すと戻る
- サーバーにない機能を止める確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://unsupported/markers'`のように、以後その機能のAPIに404を返させて読み込み直す。機能は`markers`、`preferences`、`instanceV2`。起動し直すと戻る
- ストリーミングにつながらないときの表示とポーリングの確認には、`xcrun simctl openurl '<使う端末>' 'scia-debug://streaming/offline'`で、RESTは通したままストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す
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
- worktreeの中では、fixup commitを作ることも、`rebase --autosquash`で元のcommitへまとめることも、確認なしで行ってよい。後ろに載ったユーザーのcommitのhashが作り直されても構わない
