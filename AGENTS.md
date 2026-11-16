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
- `README.md`と`FEATURES.md`の変更は、ユーザーが自分の端末で`Tools/human-review.sh approve <commit>`を走らせて承認するまで、mainに入らない（`make hooks`のhookと`Tools/merge-queue.sh`で止める）。agentは承認を走らせず、`script`などで端末を作って入力を流し込むこともしない
- `FEATURES.md`: Sciaでできることのリスト。使う人に見える機能を足したり変えたりしたら、ファイルの先頭のコメントに従って合わせる
- `docs/vision.md`: 何を作り、何を作らないかと、設計の判断の基準。作業が終わっても残す考え方を書く
- `docs/roadmap.md`: これからの作業の単位と順序。1項目1行で、何をするかだけを書く。設計の判断や、作業を進めるための細かい合意・状態・調べて分かったことは書かない。済んだ項目は消す
- docs、コメント、commit messageに書く理由は、ユーザーが示したもの、ドキュメントやコードや実際の動きで確かめた事実、技術的な制約に限る。agentが推測した理由（使う人がどう使うことが多いかの見込みなど）は、ユーザーが決めたように読めるので書かない。読めば推し量れる理由なら、書かずに済ませる。推測でも書いておきたいときは、推測だと分かる書き方にし、報告でユーザーに確かめる
- 作業を別のthreadへ引き継ぐためのメモ（合意した細部、進み具合、検証の道具など）は、元のcheckoutの`.handoff/`に置く。`.git/info/exclude`で除いてあるのでcommitされない。worktreeは作業が終わると消えるため、worktreeの中には置かない。作業が終わったら消す。親子のセッションの間では使わない。始めるセッションへの依頼の文やメッセージで直接渡す

## コマンド

- `make generate`: Xcodeプロジェクトを生成する
- `make app-info`: `Config/app-info.json`から、アプリの`AppInfo.generated.swift`と`README.md`の生成の節を書き出す
- `make lint`: `.swiftlint.yml`の規則に反する書き方をSwiftLintで検出する（`brew install swiftlint`が必要）。呼び出しや文字列の補間の形で決まる規則は、構文木で調べる`Tools/SciaLint`で検出し、`// scialint:disable:next <規則>`で外す
- `make test-lint`: `Tools/SciaLint`の規則のテスト
- `make test-core`: SciaCoreのテスト（macOS上、シミュレーター不要）
- `make test-memory-cache`: `Packages/MemoryCache`のテスト（macOS上、シミュレーター不要）
- `make build`: シミュレーター向けにビルドする
- `make test`: シミュレーターでテストする。`SIM='<端末>'`で指定もできるが、貸し借りする端末（`Scia 1`〜`Scia 4`、`Scia iPad 1`、`Scia iPad 2`、`Scia Duo`）は借りているものしか受け付けない。端末のiOSの版で初めて走らせたときは、UIKitの公開されていない作りに頼る部分のUIテスト（`SciaSystemUITests`）も走らせる。通ると、確かめた作業ツリーの中身を覚える
- `make test`の記録: 全部を走らせると、`DerivedData/test-logs/watch-<時刻>`に実行中の負荷（`load.log`）と、30秒たっても終わらないSciaCoreのテストのスタック（`<テストの名前>-<ハッシュ>.sample.txt`。名前の英数字のほかは`_`になるので、どのテストかは末尾の`test:`の行で見る）が残る。落ちた回の`.xcresult`と、その回の`watch-<時刻>`のコピーは、`DerivedData/test-logs/failed-<時刻>`に残る
- `make test ONLY='SciaTests/LinkLabelTests'`: 一部のテストだけを走らせる。手元で走り、このworktreeが借りている端末を使うので、先に借りる。識別子は空白で区切って複数渡せる。通っても中身は覚えない。`xcodebuild ... test`を直接走らせるときは、`-collect-test-diagnostics never`を付ける。付けないと、テストが失敗したときにシミュレーターの診断を集め、応答を待って10分止まる
- `make check`: 変更を報告する前に必ず通す。通ると、確かめた作業ツリーの中身（commitしていない変更も含む）を覚える
- テストが落ちたら、`DerivedData/test-logs/failed-<時刻>`のxcresultを`xcrun xcresulttool get test-results tests --path <xcresult>`で読む。別のMacで走った分も手元のここに届く。式の実際の値は`make test`の出力に残らず、ここにある。落ちたテストの前後のアプリのログ（`SciaLog`）は、`xcrun xcresulttool export diagnostics --path <xcresult> --output-path <フォルダー>`で取り出した`StandardOutputAndStandardError.txt`にある（`get log --type console`では出ない）
- `make check-test`: `make check`と`make test`を両方走らせる。アプリをビルドしてから、checkの残りを`make test`と同時に走らせるので、続けて走らせるより早い。端末の選び方と、通ったものを覚えるのは、それぞれと同じ
- `make test`、`make check`、`make check-test`は、`SIM`も`ONLY`も指定しなければ、テストを任せる別のMacと手元の、空いている枠で走らせる。端末は借りなくてよい。別のMacを優先し、どちらも満杯なら先着順に待つ。手元で走らせるときは`SCIA_REMOTE_TEST=local`を付ける（[docs/test-dispatch.md](docs/test-dispatch.md)）
- `make menu-editor`: メニューの既定の並びを並べ替えるページを、今の項目の名前と既定の並びを入れて`DerivedData/menu-editor.html`に書き出す
- `make archive`: 実機向けのReleaseビルドをアーカイブする。ビルド番号はアーカイブしたUTCの日時になる
- `make testflight`: アーカイブしてApp Store Connectへ上げる。mainは、GitHub Actions（`.github/workflows/testflight.yml`）が毎朝5時（JST）に、前に上げたときから変わっていれば上げる。上げたビルドは、`make testflight-external`で外部テストのグループ（リポジトリのvariablesの`TESTFLIGHT_EXTERNAL_GROUP`）に足し、TestFlight App Reviewに出す
- `make hooks`: ローカルのmainを、`make check`と`make test`の両方が通った中身のcommitにしか動かさないhookを入れる。checkoutごとに1回で、worktreeにも効く。通った中身との違いがMarkdown（`*.md`）とログイン画面の補完に使うサーバーのリスト（`known-servers.txt`）だけなら、走らせ直さずに通ったものとして扱う
- `make scenario-run PERSONA=<役>`: 何も知らないエージェントを、`Tools/scenario/personas/`の役で初めて使う人としてSciaに触らせ、報告とスクリーンショットを`~/scia-scenario/runs/`に残す。外へ出ないMastodon（`mastodon.localhost`）と専用の端末`Scia Scenario`を使い、Release構成のSciaを入れる。先に`make scenario-setup`で準備する（何度走らせても同じ状態になる）。DockerとAXe（`brew install cameroncooke/axe/axe`）が要る。ユーザーが`/scenario`で起動したときは、`.claude/skills/scenario`の手順で走らせてまとめる

## シミュレーター

- 動作確認とテストには、`Scia 1`、`Scia 2`、`Scia 3`、`Scia 4`のどれかのシミュレーターを使う。どれもログイン済みの端末の複製で、ログイン情報が端末のKeychainに残っているため、ログインし直さずに済む
- iPadだけ、`Scia Duo`だけ、ダークモードだけのように、起きる端末や見た目が限られた不具合は、その中だけを変えて直す。ほかの端末や見た目にも効かせるときは、理由をcommit messageに書く。直したら、ほかの端末で見え方が変わっていないことも確かめる
- `Scia Scenario`は`make scenario-*`の専用の端末で、`Tools/sim.sh`では貸し借りしない。ほかの確かめには使わない
- シミュレーターを触る直前に、`sim`のskillで端末を借り、触り終えたら返す。貸し借りの手順のほか、`Tools/sim.sh`の`dump`と`shot`での画面の読み方、iPadと`Scia Duo`（名指しで借りる）、4台が同じアカウントを共有していることの注意、simslimで止めているサービスも、skillにある
- 端末のクリップボードには、自分が`Tools/sim.sh ctl '<使う端末>' pbcopy`で入れたもの以外をペーストしない。DeviceHubの「Use Shared Clipboard」がオンだと、Macのクリップボードが端末へ書き込まれ、Universal Clipboardで届いたユーザーのiPhoneのコピーも入るため、投稿欄に貼ると仕事の内容が投稿される。`Tools/sim.sh acquire`は、借りた端末の同期を切ってクリップボードを空にする。投稿欄の本文と添付は、ペーストではなく`scia-debug://compose`の`text`と`media`で入れる。ペーストそのものを確かめるときは、貼る直前に`pbcopy`で中身を入れる
- シミュレーターのツールでは、決まった端末を毎回`device`で指定する。省略すると、他のスレッドが使っている端末を操作してしまうことがある
- 端末に命令を送る`xcrun simctl`は、直接呼ばずに`Tools/sim.sh ctl '<使う端末>' <操作> <引数...>`で送る。直接の呼び出しと、借りていない端末を指したシミュレーターのツールは、hookが止める
- 並行して作業するスレッドは、worktreeも分ける。`make build`・`make test`はworktree直下の`DerivedData`、`make test-core`は`Packages/SciaCore/.build`を使うため、同じworktreeで同時に走らせると、ロック待ちで失敗したり成果物を上書きし合ったりする
- 画面は、タップでたどらず`Tools/sim.sh ctl '<使う端末>' openurl '<URL>'`で開く。アプリの画面は`scia://`のURLで開き、デバッグ版だけの画面と操作は`scia-debug://`で開く。`scia-debug://reset`（重ねた画面を閉じてホームに戻す）のあとに続けて送ってよい。閉じ終えてから開く。IDやハンドルは、ログインしているサーバー（stellaria.network）の公開API（`api/v1/accounts/lookup?acct=`、`api/v1/accounts/<ID>/statuses`）で調べる。画面を足したら、`AppDestination`に開く先を足し、[docs/app-url.md](docs/app-url.md)の「開ける画面」にも書く。開ける画面は、そこに並べてある。`scia://`のURLは、これから足すショートカットと同じ入り口を通る
- ダミーのセッション、保存してあるアカウントへの切り替え、投稿欄やプロフィールの編集への入力、新着の保留、ソフトウェアキーボードの出し方は、[docs/debug-urls.md](docs/debug-urls.md)にある

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
- ティントカラーで塗った地に文字や記号を載せるときは、地と中身の色を`TintFill.colors(for:on:)`から取る（バッジは`TintBadgeLabel`と`TintSymbolBadge`）。中身を白に決め打ちすると、アクセントカラーがモノトーンのときにダークで白い地に白い中身になり、地を`.tintColor`のまま置くと、ガラスの中でほかのボタンより明るく描かれるため。地に`.tintColor`を直接塗る書き方は、`make lint`の`raw_tint_background`で止める。上に何も載せない地だけ、理由を書いて外す
- 失敗の理由（`ErrorPresentation`）は、`App/Sources/Notices/FailureDisplay.swift`の部品で出す。ログアウトされたアカウントがあれば、部品が「ログインし直す」を付けるため。文言はSciaCoreでSPI（`FailureDisplay`）にしてあり、部品のファイルのほかでそのSPIをimportする書き方は、`make lint`の`failure_reason_outside_display`で止める
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 文言

- 使う人に見える文言は、SciaCoreに置き、アプリ（`App/Sources`）は読むだけにする。アプリに書くと、SciaCoreだけを使う別のUI（AppKitのMac版など）が同じ文言を出せず、UIごとに言い回しがずれるため。値の型に結び付く文言はその型の`title`などに、型のない文言は画面ごとの`…Texts`に置く。アプリに日本語の文字列を書く書き方は、`make lint`の`user_text_outside_core`で止める。デバッグ版だけに入るもの（`App/Sources/Debug`、違和感レポート、`#if DEBUG`の中）、ログ、`preconditionFailure`などの理由は対象外
- 名前、ハンドル、数、日時などを埋める文言は、埋める値を受け取って文を丸ごと返す関数にする。「がブースト」のような文の一部を返して、呼ぶ側でつなげない。将来ほかの言語に訳したときに、語順が変わっても呼ぶ側を直さずに済むようにするため。文の一部だけ色や書体を変えるものも、文を丸ごと持ち、変える範囲を添えて返す（`PostTexts.EmphasizedText`）
- 使う人に見える文言は、iOSの日本語UIの標準の言い回し（設定アプリ、メール、Safariなどの表記）に倣う。前に直した言い回し（「既定」「捨てる」「消す」「止める」「端末」など）は、`make lint`の`ios_wording`で止める。規則が並べていない言い回しも、同じ操作をiOSがどう書くかを確かめてから書く
- 画面で同じ種類のアイテムを並べるとき（投票の選択肢、フィルターのキーワード、一致したフィルターの名前、割り当てた項目の名前など）は、「、」や「・」ではなく境界線で区切る。`TextLists.items`で並べ、UIKitでは`ListSeparator.attributedString`、SwiftUIでは`ItemListText`で描く。「、」は文のための記号で並べたアイテムが文に見え、「・」はアイテムの中身に入ると区切りと紛れるため（「そば・うどん」）
- 1つのものに付く、種類の違う情報を1行に並べるとき（「40票・終了」「隠す・期限切れ」「1:25:28・HTTP 404」など）は、「・」でつなぐ。項目の種類と数が決まっていて、合わせて1つの説明になるため
- 境界線を引けない、文字だけの出し先（送る文面、見本の投稿の本文など）では、同じ種類のアイテムの列挙も`TextLists.plain`で「・」にする。読み上げ（`accessibilityLabel`と`accessibilityValue`）と、文の中の列挙（「お気に入り、ブーストはなくなり…」）は「、」のままにする
- 使う人に見える文言の引用は`“”`で書く。iOSの設定アプリの書き方に合わせるため
- 状態の文言の「中」は進行中だけに使い、完了した状態は「接続済み」のように「済み」と書く。「接続中」が、つないでいる途中とつないだあとのどちらにも読めたため
- 「接続の状態」の画面（`ConnectionStatusView`）は開発者が見る画面なので、ポーリングなどの用語をそのまま使う
- 使う人に見える文言では、対象が画像だけなら「画像」、動画・GIF・音声を含むなら「メディア」と書く。代替テキストや閲覧注意のように種類を問わず付くものを、「画像」と書かない
- ユーザーの`acct`（`@user@domain`）は、使う人に見える文言では、Mastodonのwebに倣って「ハンドル」と書く。「ユーザー名」や「acct」と書かない
- 使う人に見える文言では、フォローをやめる操作を、ユーザーでもハッシュタグでも「フォローを外す」と書く。「フォローをやめる」「フォロー解除」と書かない。同じ操作を対象によって別の言葉で書かないため
- フォローの承認を待つリクエストは「フォローリクエスト」と書く。「フォローのリクエスト」と書かない。通知の文とMastodonのwebの日本語に合わせるため
- VoiceOverのヒント（`accessibilityHint`）は、文として句点で終える
- 進行中の表示（「読み込み中」「接続中」など）の末尾に「…」を付けない。長い文言の末尾が「…」で切れたのと見分けられないため
- 投稿がサーバーのフィルターに該当することは、「当たる」ではなく「一致する」と書く。使う人に見える文言だけでなく、コメント、テストの説明、カタログの見出しも揃える。残しておくと、あとの作業がその言い方に引きずられるため
- コメント、docs、テストの説明、カタログやチューニングの見出しでは、iOSやプログラミングで通じる用語を使い、和語に言い換えない。「払う」は「スワイプ」、「弾み」「ばね」は「バウンス」「スプリング」、「札」は添付ファイルなら「バッジ」・返信先や編集なら「ラベル」、閲覧注意の「覆い」は「ぼかし」、「畳む」は「折りたたむ」、「台本」は「シナリオ」、辞書の「鍵」は「キー」と書く。「印」は1語で済ませず、アイコン、チェックマーク、記号、インジケーターなど指すものの名前で書く

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

見た目と動きは、どのコマを止めても、そのまま人に見せられる1枚になっているかで判断する。いちばん厳しいデザイナーが、どれかのコマのスクリーンショットに「これは何？」と添えて送り返してくる場面が思い浮かぶなら、それが次に直すところ。以下の項目は、この基準で見るときの例で、項目を見終えても確かめ終えたことにはならない

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、タイムラインの上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- タイムラインの行を足す・消す・描き直す経路を足したら、[docs/vision.md](docs/vision.md)の「タイムラインの動き」のどれに当たるかを決め、`setEntries`の`animatesRemoval`などで渡す。使う人の操作で消えるのに動かない、操作によらない変化で読んでいる行が動く、のどちらも起こさないよう、動くかどうかをテストに残す
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中にスワイプする、閉じた直後に別の画像をタップする、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- トランジションの品質チェック: 本物のビューの代わりに複製を動かす開閉（ビューアの開閉、投稿欄とカプセルのあいだなど）を足したり変えたりしたら、動き始めと着地の両端で、複製と本物の見え方が一コマで切り替わらないかを確かめる。見比べる項目は、位置と大きさ、角度、角の丸み、フチ（太さと色）、影（下の面に落とす影と、重なったもの同士の影）、中身（画像か下地か、濃さ、暗さ）、上に重ねた表示（バッジ、再生アイコン、ぼかし）、重なり順（手前にあるはずのものが手前にあるか）、まわりのビュー（隠した本物が残す空き、隣の写真）。どれも、複製を本物に近づけるにつれて本物の見え方へ移すか、着いてから浮かび上がらせる。確かめるときは、時間を伸ばして録画し、両端の前後数コマを切り出して並べ、項目ごとに見る。動いている途中のコマだけを見て済ませない。テストでは、両端で複製の見え方が本物と同じになっていることを確かめる
- 動きの録画: `Tools/sim.sh ctl '<使う端末>' spawn defaults write net.mizle.scia tuning.<項目のid> -float <値>`でチューニングの値（閉じる時間など）を一時的に伸ばし、`Tools/sim.sh ctl '<使う端末>' io recordVideo --force <ファイル>`をバックグラウンドで起動して録画し（`pkill -INT -f "recordVideo --force <ファイル>"`で止める。ファイルで絞らないと、他のスレッドの録画まで止めてしまう）、ffmpegの`fps=30,crop=...,tile=...`でコマを並べて見る。見たい部分（バーの付近など）を切り出して連続したコマで比べると、1コマだけの切り替わりにも気づける。確認が終わったら`defaults delete`で必ず戻す
- シミュレーターのツールの`touch_path`は、同じ座標の点を動きとして送らない。最後に同じ点を並べて指を止めた形にしても、離した瞬間の速さが残って慣性で流れる。位置を決めたいドラッグには、終点で細かく揺らして速さを0にする`Tools/sim.sh drag <x1> <y1> <x2> <y2>`の点の並びを渡す。最初の20〜80ptはスクロールが始まるまでの遊びに吸われるので、動かしたあとに`contentOffset.y`を測って足りない分を足す。ページめくりやスワイプして閉じる操作は、速さで決まるので`swipe`で行う
- どこを押すとどのビューが受けるかは、`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://hit-areas/on'`で、すべての画面の上に、受けるビューごとに色を分けた範囲と型の名前を重ねて見る。デバッグメニューの「当たり判定を表示」でも切り替えられ、`hit-areas/off`か起動し直すと消える。範囲は`hitTest`で調べるので、アニメーションの途中も行き先の位置に出る。タイムラインの画面では調べて描き直すのに2秒ほどかかり、その間は前の結果を出しておくので、画面を移ったりスクロールしたりした直後は、撮り直して確かめる。SwiftUIの部品の中は1つの範囲になる
- タップが効かないなど、どのビューが触れたものを受けているか分からないときは、lldbで実行中のアプリにつなぎ（`lldb -p <pid> --batch -s <コマンドのファイル>`）、`expr -l swift -O -- `でウィンドウの`hitTest`やビュー階層（`recursiveDescription`）を調べる
- 実物で出しにくい状態は、検証のための`scia-debug://`のURLで作る。ダミーの投稿と通知、APIの応答と同じ形のJSONを流す`inject`、サーバーの障害・401・読めない応答・サーバーにない機能・ストリーミングの切断、ダウンロードやアップロードなどの遅延、チップ、ステータスバーの通知、クラッシュ、自動翻訳、ストレージ、ハッシュタグとリスト、実機の自動スクロールがあり、[docs/debug-urls.md](docs/debug-urls.md)に並べてある。確かめる前に読み、同じ仕組みを作らない。検証の機能を足したら、そこに足す
- 部品の状態ごとの見た目（失敗の表示など）は、失敗を起こさずに、デバッグメニューの「部品カタログ」で並べて見る。agentは起動済みのアプリへ`Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://catalog/<部品>'`で開く。部品は`App/Sources/Debug/Catalog/ComponentCatalog.swift`の`CatalogComponent`にあり、状態は同じフォルダーの部品ごとのファイルに並べる
- 部品の見た目を足したり変えたりしたら、次に当てはまる状態をカタログに足すか直す。状態を足した、消した、文言を変えたときも合わせる
  - 実物で出すのに手間や副作用がある状態（サーバーの失敗、アップロードの途中、ログインし直し、ストリーミングの切断など）
  - 文言や数の長さで崩れうる状態（長い名前、上限超え、件数）
  - ほかの表示と重なる組み合わせ
- 状態が1つしかないか実物ですぐ出せる見た目、動きや間合い（アニメーション、ジェスチャー、スクロール位置）、画面をまたぐ流れは、カタログに載せない。動きはチューニングと録画で確かめる
- カタログは状態を直接渡し、置き場所も実物をまねたものなので、その状態にたどり着くかと、置かれた場所での見え方（ほかの表示との重なり、安全領域、キーボード）は確かめられない。ふだん通る流れは実物で撮り、失敗の流れも`scia-debug://status/502`などで実物で一度は通す。カタログでは、実物で出しにくい状態と、文言や長さの違いを見比べる
- 部品の見た目を変えた作業の報告には、カタログに足した状態か載せない理由と、どの状態を実物で見て、どの状態をカタログだけで見たかを書く
- 「投稿の見た目」の項目や見本、投稿の行の描き方を変えたら、すべての項目と選択肢を変える前と後に並べた画像を作って、全部見る。`TEST_RUNNER_SCIA_APPEARANCE_SHEETS=1 make test ONLY='SciaTests/AppearanceSheets'`で、`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`のtmp/AppearanceSheetsに書く。示す帯（赤）が変わった部分と合っているか、変えて崩れないかを確かめる。いくつかをつまんで見るだけでは、ずれに気づけない
- 描画性能: スクロール時のhitchは`xcrun xctrace record --template 'Animation Hitches'`や`XCTOSSignpostMetric.scrollDecelerationMetric`で測る。シミュレーターの値は参考値で、最終確認は実機で行う
- 見た目: 実データに近いfixtureを使い、スクリーンショットで確認する
- 好みで決まる値は、ハードコードで決め打ちしない。余白や文字の大きさのような投稿の見た目の値は、設定の「投稿の見た目」（`AppearanceCatalog`）に項目を足す。アニメーションの時間や新着をまとめて挿入する間隔のような、動きや間合いの値は、`TuningCatalog`に項目を足してデバッグ用のチューニングパネルから調整できるようにする。足した項目は`sections`にも並べる（入れ忘れると、パネルに出ず、`defaults write`で入れた値も読まれない。`make lint`の`tuning_item_not_in_sections`で止める）。パネルはデバッグメニューから開くが、値はデバッグメニューを出していないReleaseでも`TuningStore`から読むので、SciaCoreのモデルには、どのUIも`TuningStore`を作って渡す。どちらも、ユーザーに選んでもらう
- フレームが落ちたスクロールでは、落ちたフレームに使った処理の時間（行の組み立て、行の大きさの計算、並べ直しなど）を、`frameWork`のnoticeのログに1行で残し、アプリのDocuments/FrameWork.jsonに起動をまたいで足し上げる。直す場所を選ぶときは、まずこのファイルで合計の長い処理を見る。測るのは`FrameWork.measure`で囲んだ処理だけなので、`measured`が`hitchTime`よりずっと小さければ、測っていない処理が重い。そのときは`FrameWork.measure`で囲む場所を足すか、Time Profilerで測る
- デバッグメニューは、デバッグ版では常に出す。Releaseでは、設定の「情報」の「ビルド」の行を7回タップするとオンになり（同じ操作でオフに戻る）、チューニング、部品カタログ、違和感レポート、当たり判定の表示、HDRの余地の表示だけを出す。通信や既読位置を変える検証の項目と`scia-debug://`は、DEBUGのビルドだけに入れる
- 違和感レポートは、デバッグメニューから開く。シェイクで開くのはデバッグ版だけ。ユーザーが残した違和感レポートは、アプリのDocuments/DiscomfortReportsにJSONで保存される。シミュレーターでは`xcrun simctl get_app_container '<使う端末>' net.mizle.scia data`で場所を調べられる。状態を追いたい画面は`AppDependencies.stateDumps`に状態ダンプを登録し、調査に必要なイベントはinfo以上のレベルで`SciaLog`に出す（debugレベルはレポートに残らない）

## コメント

- コメントは、書いたあとに削るのではなく、書く前に要るかを判断する。行ごとに、消しても読み手が困るかを確かめる
- 残すのは、そのコードに固有の判断で、コードからは読み取れない制約だけにする（OSの不具合への対処、守らなければならない呼び出しの順番、変えてはいけない値など）
- 次の行を言い直すコメント、不具合の経緯、ライブラリの一般的な動き方の説明は書かない。経緯と変えた理由はcommit messageに書く
- 前例のコメントに倣うときも、前例にある分だけにとどめる
- 変更で正しくなくなったコメントは消すか直す

## テスト

- テストはSwift Testing（`import Testing`）で書く
- APIレスポンスのfixtureは`Packages/SciaCore/Tests/SciaCoreTests/Fixtures/`に置く。実サーバーのレスポンスを使う場合は、個人を特定できる情報を置き換える
- バグ修正では先に失敗するテストを書き、直す前のコードで失敗することを確かめてから直す
- 変更した処理を差し替え、差し替えたものの呼ばれ方や返した値を確かめるだけのテストは書かない。変更した処理そのものを通らないので、壊れても落ちないため
- 決め打ちの文言を直すだけの修正には、直した文字列を書き写して比べるテストを足さない。文言を変えるたびにテストも同じように書き換えるだけで、取り違えも退行も止めないため。テストを書く前に、どんな取り違えや退行を止めるかを一文で言えるか確かめ、言えなければ書かない。読み戻し、分岐、計算が絡む修正では、先に失敗するテストを書く
- アプリのテスト（`AppTests`）のsuiteには`@Suite(.failureState)`を付ける。落ちた時点のウィンドウ、フォーカスのある入力欄、画面の状態ダンプ（`AppDependencies.stateDumps`）を失敗のメッセージに添えるので、確認ごとに状態を出す文を書かなくてよい（`make lint`の`suite_without_failure_state`で止める）。落ちたときに要る状態がここに出ない画面は、状態ダンプを登録するか足す
- テストで作る一時ファイルと設定の保存先（`UserDefaults(suiteName:)`）は、`SciaTesting`の`TestScratch`で作り、テストかスイートに`.scratch`を付ける。テストの終わりと次に走らせたときに消すので、走らせるたびに溜まらない（`make lint`の`test_file_without_scratch`で止める）
- テストは実際の時間や今の時刻に頼らせない（`make lint`の`time_dependent_test`で止める）。時間をおく処理には`SciaTesting`の手で進める`Clock`（`TestClock`）を渡し、アニメーションは層の時計（`LayerClock`）、毎フレーム進める動きは手で送るコマ（`ManualFrameSource`）で進める。ほかの処理は門（`Gate`）か条件（`waitUntil`）で待ち（`Task.yield`で譲って待たない。`make lint`の`yield_based_waiting`で止める）、日時は決まった値で作る。止めたあとに何も起きないことは、時間を待たずに、走り終えていない処理の数や予約が残っていないことで確かめる
- 実物のコーデックやファイルの書き出しのように、かかる時間を差し替えられない処理のテストは、`.timeLimit`ではなく`.stallLimit`を付け、段階が進むたびに`StallProgress.current`の`note`で伝える。テスト全体の時間で見ると、ほかのビルドと重なってシミュレーターのコーデックが100倍以上遅くなった回に、固まっていないのに落ちるため
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
