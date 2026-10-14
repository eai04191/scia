# AGENTS.md

SciaはストリーミングAPIでタイムラインが流れる、手触りの良いiOS向けMastodonクライアントです。将来はmacOSにも対応します。何を作り、何を作らないかは[docs/vision.md](docs/vision.md)、作業の単位と順序は[docs/roadmap.md](docs/roadmap.md)を参照してください。

## 構成

- `project.yml`: XcodeGenの定義。`Scia.xcodeproj`と`App/Info.plist`は生成物なのでコミットせず、直接編集しない。ターゲットや設定の変更は`project.yml`で行う
- `Packages/SciaCore`: UIに依存しないロジック（モデル、APIクライアント、ストリーミング、タイムラインの状態管理）。iOSとmacOSで共有するため、UIKit／AppKit／SwiftUIをimportしない
- `App/Sources`: iOSアプリ（UIKitライフサイクル）

## コマンド

- `make generate`: Xcodeプロジェクトを生成する
- `make lint`: SwiftLintで強制アンラップ、`try!`、IUOを検出する（`brew install swiftlint`が必要）
- `make test-core`: SciaCoreのテスト（macOS上、シミュレーター不要）
- `make build`: シミュレーター向けにビルドする
- `make test SIM_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro'`: シミュレーターでテストする
- `make check`: 変更を報告する前に必ず通す

## シミュレーター

- 動作確認とテストには`iPhone 16 Pro`のシミュレーターを使う。ログイン情報は端末のKeychainに残るため、端末を揃えればスレッドやworktreeをまたいでもログインし直さずに済む
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- シミュレーターのツールで文字を入力すると、ハードウェアキーボードがつながった扱いになり、ソフトウェアキーボードが出なくなる。キーボードが出た状態を確かめるときは、`xcrun simctl shutdown 'iPhone 16 Pro' && xcrun simctl boot 'iPhone 16 Pro'`で再起動し、文字を入力せずタップだけで入力欄にフォーカスする。再起動ではKeychainが残るため、ログインし直さずに済む

## 設計原則

- ロジックはできるだけSciaCoreに置き、`swift test`で検証できる形にする。アプリ側はSciaCoreの状態を描画するだけの薄い層に保つ
- タイムラインはUICollectionViewとdiffable data sourceで組む。スクロール位置を細かく制御する必要があるため、SwiftUIのListやScrollViewにはしない
- 独自のアニメーションやジェスチャーを足す前に、UIKit標準の部品と挙動で実現できないか検討する
- Mastodon APIの仕様は推測せず、公式ドキュメント（https://docs.joinmastodon.org/ ）で確認する。サーバー実装による差異（glitch-soc、Fedibird、GoToSocialなど）は、必要になった時点で個別に対応してテストに残す
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、一覧の上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中に払う、閉じた直後に別の画像を叩く、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- 描画性能: スクロール時のhitchは`xcrun xctrace record --template 'Animation Hitches'`や`XCTOSSignpostMetric.scrollDecelerationMetric`で測る。シミュレーターの値は参考値で、最終確認は実機で行う
- 見た目: 実データに近いfixtureを使い、スクリーンショットで確認する
- 好みで決まる値（アニメーションの時間、余白、新着をまとめて挿入する間隔など）は、ハードコードで決め打ちせず、`TuningCatalog`に項目を足してデバッグ用のチューニングパネルから調整できるようにし、ユーザーに選んでもらう
- ユーザーがシェイクで残した違和感レポートは、アプリのDocuments/DiscomfortReportsにJSONで保存される。シミュレーターでは`xcrun simctl get_app_container 'iPhone 16 Pro' net.mizle.scia data`で場所を調べられる。状態を追いたい画面は`AppDependencies.stateDumps`に状態ダンプを登録し、調査に必要なイベントはinfo以上のレベルで`SciaLog`に出す（debugレベルはレポートに残らない）

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
