# AGENTS.md

SciaはストリーミングAPIでタイムラインが流れる、手触りの良いiOS向けMastodonクライアントです。将来はmacOSにも対応します。何を作り、何を作らないかは[docs/vision.md](docs/vision.md)、作業の単位と順序は[docs/roadmap.md](docs/roadmap.md)を参照してください。

## 構成

- `project.yml`: XcodeGenの定義。`Scia.xcodeproj`と`App/Info.plist`は生成物なのでコミットせず、直接編集しない。ターゲットや設定の変更は`project.yml`で行う
- `Config/Local.xcconfig`（署名のチームなど）と`Config/CacheLocal.xcconfig`（コンパイルキャッシュの置き場所）は人ごとの設定で、コミットしない。なくてもシミュレーター向けにはビルドできる
- `Packages/SciaCore`: UIに依存しないロジック。iOSとmacOSで共有するため、UIKit／AppKit／SwiftUIをimportしない。別のUIから何を使うかの入口は[docs/other-ui.md](docs/other-ui.md)。別のUIも使う部品を足したり、決まりをUIからSciaCoreへ移したりしたら、そのdocsにも足す
- `Packages/MemoryCache`と`Packages/TextKit2Label`はSciaに依存しない部品で、パッケージを分けてコンパイラーで守る。絵文字やリンクを扱うラベルは、アプリでTextKit2Labelの`TextKitLabel`を派生させて作る。TextKit2LabelはUIKitに依存するので、テストは`make test`でシミュレーターで走る

## 文書の使い分け

- `docs/`はagentが読む文書で、人は読まない。人が読むのは`README.md`と`FEATURES.md`で、`docs/`とは別物として扱う
- 例外として、`docs/server-compatibility.md`は人も読む。ほかのMastodon互換の実装の開発者に見せるため、短く平易に書き、書き方はファイルの先頭のコメントに従う。ほかの実装のための手当てを足したり外したりしたら、合わせる
- `README.md`と`FEATURES.md`の変更は、ユーザーが自分の端末で`Tools/human-review.sh approve <commit>`を走らせて承認するまで、mainに入らない。agentは承認を走らせず、`script`などで端末を作って入力を流し込むこともしない
- `FEATURES.md`: Sciaでできることのリスト。使う人に見える機能を足したり変えたりしたら、ファイルの先頭のコメントに従って合わせる
- `docs/vision.md`: 何を作り、何を作らないかと、設計の判断の基準。作業が終わっても残す考え方を書く
- `docs/roadmap.md`: これからの作業の単位と順序。1項目1行で、何をするかだけを書く。設計の判断や、作業を進めるための細かい合意・状態・調べて分かったことは書かない。済んだ項目は消す
- docs、コメント、commit messageに書く理由は、ユーザーが示したもの、ドキュメントやコードや実際の動きで確かめた事実、技術的な制約に限る。agentが推測した理由（使う人がどう使うことが多いかの見込みなど）は、ユーザーが決めたように読めるので書かない。読めば推し量れる理由なら、書かずに済ませる。推測でも書いておきたいときは、推測だと分かる書き方にし、報告でユーザーに確かめる
- 作業を別のthreadへ引き継ぐためのメモ（合意した細部、進み具合、検証の道具など）は、元のcheckoutの`.handoff/`に置く。commitされず、worktreeは作業が終わると消えるため、worktreeの中には置かない。作業が終わったら消す。親子のセッションの間では使わず、始めるセッションへの依頼の文やメッセージで直接渡す
- リポジトリのスキルは`.agents/skills/<名前>/`を正とし、Claude Codeは`.claude/skills/<名前>`の相対シンボリックリンクから同じ実体を読む。スキルを追加するときはリンクもGitに含め、リンク先はそのworktree内にする。Claude専用のプラグイン（`scia-session-id`）は`.claude/skills/`に置く。明示起動だけのスキルは、Claude Codeの`disable-model-invocation: true`とCodexの`agents/openai.yaml`の`policy.allow_implicit_invocation: false`を両方設定する
- スキルの本文を共有しても、エージェント固有のツールやhookは共用されない。スキルに指定されたツールがないときは、その手順を実行できると判断しない

## コマンド

- `make generate`: Xcodeプロジェクトを生成する
- `make lint`: SwiftLintと、呼び出しや文字列の補間の形を構文木で調べる`Tools/SciaLint`で、決まりに反する書き方を検出する（`brew install swiftlint`が必要）。SciaLintの規則は`// scialint:disable:next <規則>`で外す
- `make test-core`: SciaCoreのテスト（macOS上、シミュレーター不要）
- `make build`: シミュレーター向けにビルドする
- `make test`: シミュレーターでテストする。`SIM='<端末>'`で指定もできるが、貸し借りする端末は借りているものしか受け付けない。端末のiOSの版で初めて走らせたときは、UIKitの公開されていない作りに頼る部分のUIテスト（`SciaSystemUITests`）も走らせる
- `make test ONLY='SciaTests/LinkLabelTests'`: 一部のテストだけを走らせる。手元で走り、このworktreeが借りている端末を使うので、先に借りる。識別子は空白で区切って複数渡せる。`xcodebuild ... test`を直接走らせるときは、`-collect-test-diagnostics never`を付ける。付けないと、テストが失敗したときにシミュレーターの診断を集め、応答を待って10分止まる
- `make check`: 変更を報告する前に必ず通す
- `make check-test`: `make check`と`make test`を、続けて走らせるより早く両方走らせる
- `make test`、`make check`、`make check-test`は、`SIM`も`ONLY`も指定しなければ、テストを任せる別のMacと手元の空いている枠で走らせるので、端末は借りなくてよい。通ると、確かめた作業ツリーの中身を覚え、mainに入れるときに使う。どちらで走っても、通ったビルドのアプリが`DerivedData/checked/Scia.app`に置かれるので、そのあとコードを変えていなければ、`make build`せずにこれをシミュレーターに入れる。手元で走る`make check`と同時に`make build`しないため、通るのを待たずに確かめたいときは、`make check`の前に`make build`する。手元で走らせるときは`SCIA_REMOTE_TEST=local`を付ける。テストが落ちたら、`DerivedData/test-logs/failed-<時刻>`のxcresultを読む。振り分けと落ちたテストの記録の読み方は[docs/test-dispatch.md](docs/test-dispatch.md)にある
- ほかのターゲット（Releaseのテスト、TestFlight、`make scenario-run`など）は、Makefileの`##`のコメントにある。謝辞、ライセンス、プライバシーポリシーのリンクは`Config/app-info.json`だけを編集し、`make app-info`で書き出す

## シミュレーター

- 動作確認とテストには、`Scia 1`、`Scia 2`、`Scia 3`、`Scia 4`のどれかのシミュレーターを使う。どれもログイン済みで、ログインし直さずに済む
- シミュレーターを触る直前に、`sim`のskillで端末を借り、触り終えたら返す。端末の操作の決まり（クリップボード、URLで画面を開く、iPadと`Scia Duo`、画面の読み方）は、そのskillにある
- iPadだけ、`Scia Duo`だけ、ダークモードだけのように、起きる端末や見た目が限られた不具合は、その中だけを変えて直す。ほかの端末や見た目にも効かせるときは、理由をcommit messageに書く。直したら、ほかの端末で見え方が変わっていないことも確かめる
- 並行して作業するスレッドは、worktreeも分ける。`make build`・`make test`はworktree直下の`DerivedData`、`make test-core`は`Packages/SciaCore/.build`を使うため、同じworktreeで同時に走らせると、ロック待ちで失敗したり成果物を上書きし合ったりする
- 画面を足したら、`AppDestination`に開く先を足し、[docs/app-url.md](docs/app-url.md)の「開ける画面」にも書く。`scia://`のURLは、これから足すショートカットと同じ入り口を通る

## 設計原則

- 別の機能の画面や内部部品を、見た目を再利用するためだけに直接参照しない。複数の機能で必要な描画は、特定の機能に依存しない共通部品へ分離し、各機能から使う。
- ロジックはできるだけSciaCoreに置き、`swift test`で検証できる形にする。アプリ側はSciaCoreの状態を描画するだけの薄い層に保つ
- 非決定的な外部依存（今の時刻、時間の経過、乱数、UUID、通信、ファイル、OSの状態など）は、ロジックの内部で直接生成・取得せず、テストで差し替え可能な境界に集約する。時間をおく処理は標準の`Clock`（`any Clock<Duration>`）で受け取り、待つ関数や独自の時計の型で受け取らない。期限や残りの長さは`stopwatch(on:)`で測る。日付としての今が要るときは今の日付を返す関数を、Core Animationの時間が要るときはその時間を返す関数を受け取る
- セッションの持ち物（各タイムライン、開いた画面、投稿欄）で始める処理は、セッションの持ち主（`TaskScope`）の子で始める。`make lint`の`session_task_outside_scope`は並べたファイルしか調べないので、新しい画面ではlintが通っても守る
- タイムラインはUICollectionViewとdiffable data sourceで組む。スクロール位置を細かく制御する必要があるため、SwiftUIのListやScrollViewにはしない
- 独自のアニメーションやジェスチャーを足す前に、UIKit標準の部品と挙動で実現できないか検討する
- UIKitの動きは、`UIView.animateSpring(duration:bounce:in:)`で書き、`UIViewPropertyAnimator`で動かすときは`UISpringTimingParameters(duration:bounce:)`で同じスプリングにする。`animateSpring`は、UIKitのスプリングを層のアニメーションで止まるところまで動かし、動いている間は120Hzを頼む。SwiftUIのスプリングを`UIView.animate(_:changes:completion:)`に渡す書き方は、アプリの中で毎コマ値を入れて動かすので、120Hzの画面でも60Hzで描かれる。`UIView.animate(withDuration:)`の既定の加減速や`usingSpringWithDamping`、`UIView.animate(springDuration:)`でも書かず、前の書き方で残っている動きは、その箇所に手を入れるときに置き換える。OSから渡る時間と曲線に合わせる動き（キーボードの出入りに付いて動く投稿欄など）は、渡された値のまま動かす
- 画面の骨格、スクロール位置の制御、入力（入力欄、変換、キー操作、フォーカス）、ジェスチャーはUIKitで作る。中に入力もスクロール位置の精密な制御も持たない表示の部品は、SwiftUIで作れないかを先に考え、UIKitの画面に`UIHostingController`で載せる。Liquid Glassの組み方（`glassEffect`、`ConcentricRectangle`、`.containerShape`）をそのまま使えるため。UIKitで作った部品でLiquid Glassの不都合が出たら、SwiftUIへの置き換えを候補に入れる
- `UIViewRepresentable`で包む部品は`sizeThatFits`で大きさを決める。中身が大きさの希望を変え続けて、並べ直しが止まらなくなることがあるため
- 人が書く文字の入力欄は`GlyphLanguageTextView`か`GlyphLanguageTextField`で作り、ほかのUIKitの入力欄（検索欄、アラートの入力欄など）では`smartInsertDeleteType = .offOnMac`を入れる。スマート挿入は、英字の後ろに「─」を貼ると「abc ─」のように、ペーストした文字の前に空白を足す。iOSでは設定のスマート句読点に従うので既定のままにし、Macで動くときだけ切る。Macでは、Macのスマート引用符とスマートダッシュを切っても空白が付いたため、iOSのキーボード設定が届いていないと見ている（直接は確かめていない）。SwiftUIの入力欄（`TextEditor`、`TextField`、`.searchable`）は、SwiftUIから切れない
- `Form`や`List`で作る画面（設定、通報など）を作ったり変えたりするときは、[docs/form-list.md](docs/form-list.md)に従う
- Mastodon APIの仕様は、公式ドキュメント（https://docs.joinmastodon.org/ ）で確認する。サーバー実装による差異は、必要になった時点で個別に対応してテストに残す。要求はまずMastodonが想定している形で送り、ほかの実装への手当ては、その結果を見てから足す
- サーバー（ほかのサーバーの利用者が書いた投稿や、fxtwitterの応答を含む）から来る件数、上限、URLは、読むところで`decodeCount`、`ServerLimit`、`decodeURL`で確かめる。読んだあとの計算でも、サーバーの値から作った数（縦横比や割合）を整数に直す前に、範囲に収める
- ファイルやフォルダーの名前は、文字列の決まった名前でなければ`SafeFileName`で作り、`appending(fileName:)`でつなげる
- ログと状態ダンプに何を`privacy: .public`で出してよいかは、[docs/logging.md](docs/logging.md)に従う
- ティントカラーで塗った地に文字や記号を載せるときは、地と中身の色を`TintFill.colors(for:on:)`から取る（バッジは`TintBadgeLabel`と`TintSymbolBadge`）
- サーバーの上限のうち、APIで返らないもの（メモや通報のコメントの文字数など）は、Mastodonのソースにある値でも手元で固定しない。Mastodonはソースを変えて動かせるので、上限を変えたサーバーで、書ける長さを手元で止めたり、断られる長さを通したりするため。手元では止めず、サーバーが断って返す理由を、送れなかったときの表示で出す。文字数のような目安は、上限を付けずに出してよい
- Swift 6のstrict concurrencyを有効にしている。`@unchecked Sendable`や`nonisolated(unsafe)`で警告を消さず、設計で解決する

## 文言

- 使う人に見える文言は、SciaCoreに置き、アプリ（`App/Sources`）は読むだけにする。値の型に結び付く文言はその型の`title`などに、型のない文言は画面ごとの`…Texts`に置く
- 名前、ハンドル、数、日時などを埋める文言は、埋める値を受け取って文を丸ごと返す関数にする。「がブースト」のような文の一部を返して、呼ぶ側でつなげない。ほかの言語に訳したときに、語順が変わっても呼ぶ側を直さずに済むようにするため。文の一部だけ色や書体を変えるものも、文を丸ごと持ち、変える範囲を添えて返す（`PostTexts.EmphasizedText`）
- 使う人に見える文言は、iOSの日本語UIの標準の言い回し（設定アプリ、メール、Safariなどの表記）に倣う。`make lint`の`ios_wording`が並べていない言い回しも、同じ操作をiOSがどう書くかを確かめてから書く。Mastodonの用語は、Mastodonのwebの日本語に合わせ、同じものを対象によって別の言葉で書かない（`acct`は「ハンドル」、フォローをやめる操作はユーザーでもハッシュタグでも「フォローを外す」、承認を待つリクエストは「フォローリクエスト」、サーバーにあるアカウントの設定は「アカウント設定」）
- 画面には次の操作に要る言葉だけを置く。見出しや名前の言い直し、見えている部品が何をするかの説明（「下のボタンで〜できます」）、画面の作りや設計の理由（「リアルタイムで更新されます」）、入力欄のラベルとプレースホルダーの重複、状態から描かずにいつも出るバッジやインジケーター、iOSの標準の作りにないところへ飾りとして足したアイコンは置かない。確認の本文は操作で起きることだけを書く（言うことが「取り消せない」だけなら「この操作は取り消せません。」）。失敗、空の状態、なぜ変えられないか、推し量れない制約のように、次の操作を決めるのに要る説明は書く
- 文言を直すときは削ることを先に考え、書き直す文言には画面かコードにある事実だけを入れる。削ってその要素の名前がなくなるなら`accessibilityLabel`に移す。文言を書いたり変えたりしたら、報告に旧→新をすべて並べる
- 画面で同じ種類のアイテムを並べるとき（投票の選択肢、フィルターのキーワードなど）は、「、」や「・」ではなく境界線で区切る（`TextLists.items`で並べ、UIKitでは`ListSeparator.attributedString`、SwiftUIでは`ItemListText`で描く）。「・」はアイテムの中身に入ると区切りと紛れるため（「そば・うどん」）。境界線を引けない、文字だけの出し先（送る文面、見本の投稿の本文など）では、`TextLists.plain`で「・」にする。読み上げと文の中の列挙は「、」にする
- 1つのものに付く、種類の違う情報を1行に並べるとき（「40票・終了」「1:25:28・HTTP 404」など）は、「・」でつなぐ
- 使う人に見える文言の引用は`“”`で書く
- 状態の文言の「中」は進行中だけに使い、完了した状態は「接続済み」のように「済み」と書く。進行中の表示（「読み込み中」など）の末尾に「…」を付けない。長い文言の末尾が「…」で切れたのと見分けられないため
- 対象が画像だけなら「画像」、動画・GIF・音声を含むなら「メディア」と書く。代替テキストや閲覧注意のように種類を問わず付くものを、「画像」と書かない
- 操作に伴って起きることは、受け身で書く（「ウェブサイトからはログアウトされます。」）。操作の目的ではなく、ついでに起きることだと読めるようにするため
- VoiceOverのヒント（`accessibilityHint`）は、文として句点で終える
- 「接続の状態」の画面（`ConnectionStatusView`）は開発者が見る画面なので、ポーリングなどの用語をそのまま使う
- 投稿がサーバーのフィルターに該当することは、「当たる」ではなく「一致する」と書く。使う人に見える文言だけでなく、コメント、テストの説明、カタログの見出しも揃える。残しておくと、あとの作業がその言い方に引きずられるため
- コメント、docs、テストの説明、カタログやチューニングの見出しでは、iOSやプログラミングで通じる用語を使い、和語に言い換えない。「払う」は「スワイプ」、「弾み」「ばね」は「バウンス」「スプリング」、「札」は添付ファイルなら「バッジ」・返信先や編集なら「ラベル」、閲覧注意の「覆い」は「ぼかし」、「畳む」は「折りたたむ」、「台本」は「シナリオ」、辞書の「鍵」は「キー」と書く。「印」は1語で済ませず、アイコン、チェックマーク、記号、インジケーターなど指すものの名前で書く

## 手触りに関わる変更の検証

手触りは最終的にユーザーが実機で判定する。agentは、判定に入る前に測れるものを測っておく。

見た目と動きは、どのコマを止めても、そのまま人に見せられる1枚になっているかで判断する。いちばん厳しいデザイナーが、どれかのコマのスクリーンショットに「これは何？」と添えて送り返してくる場面が思い浮かぶなら、それが次に直すところ。以下の項目は、この基準で見るときの例で、項目を見終えても確かめ終えたことにはならない

- スクロール位置: 新着の挿入、ギャップの読み込み、再接続に加え、タイムラインの上に画面を重ねて開閉する操作（添付ファイルのビューアなど）の前後でも、基準セルの画面上の位置が変わらないことをテストで確認する
- タイムラインの行を足す・消す・描き直す経路を足したら、[docs/vision.md](docs/vision.md)の「タイムラインの動き」のどれに当たるかを決め、`setEntries`の`animatesRemoval`などで渡す。使う人の操作で消えるのに動かない、操作によらない変化で読んでいる行が動く、のどちらも起こさないよう、動くかどうかをテストに残す
- 動き: アニメーションの途中でも操作を止めない。確認では、チューニングで時間を一時的に伸ばしたうえで、動いている途中に次の操作（開く途中にスワイプする、閉じた直後に別の画像をタップする、閉じる途中にスクロールするなど）を送る。1操作ずつ送る確認では間合いの問題に気づけない
- トランジション: 本物のビューの代わりに複製を動かす開閉（ビューアの開閉、投稿欄とカプセルのあいだなど）を足したり変えたりしたら、動き始めと着地の両端で、複製と本物の見え方が一コマで切り替わらないかを、[docs/motion-verification.md](docs/motion-verification.md)の項目ごとに録画で確かめる。動いている途中のコマだけを見て済ませない
- 動きを確かめる前に、[docs/motion-verification.md](docs/motion-verification.md)を読む。時間を伸ばした録画、位置を決めるドラッグ、当たり判定の表示、lldbでの調べ方、hitchの測り方がある
- 実物で出しにくい状態は、検証のための`scia-debug://`のURLで作る。確かめる前に[docs/debug-urls.md](docs/debug-urls.md)を読み、同じ仕組みを作らない。検証の機能やデバッグメニューの項目を足したら、そこに足す
- 部品の見た目を足したり変えたりしたら、[docs/component-catalog.md](docs/component-catalog.md)に従って、部品カタログの状態を合わせ、報告に書く
- 「投稿の見た目」の項目や見本、投稿の行の描き方を変えたら、[docs/appearance.md](docs/appearance.md)の「変えたときの確かめ」で、すべての項目と選択肢の前後を並べた画像を全部見る
- 見た目は、実データに近いfixtureを使って確かめる
- 好みで決まる値は、ハードコードで決め打ちしない。余白や文字の大きさのような投稿の見た目の値は、設定の「投稿の見た目」（`AppearanceCatalog`）に項目を足す。アニメーションの時間や新着をまとめて挿入する間隔のような、動きや間合いの値は、`TuningCatalog`に項目を足してデバッグ用のチューニングパネルから調整できるようにする。値はReleaseでも`TuningStore`から読むので、SciaCoreのモデルには、どのUIも`TuningStore`を作って渡す。どちらも、ユーザーに選んでもらう
- 状態を追いたい画面は`AppDependencies.stateDumps`に状態ダンプを登録し、調査に必要なイベントはinfo以上のレベルで`SciaLog`に出す。debugレベルは違和感レポートに残らない

## コメント

- コメントは、書いたあとに削るのではなく、書く前に要るかを判断する。行ごとに、消しても読み手が困るかを確かめる
- 残すのは、そのコードに固有の判断で、コードからは読み取れない制約だけにする（OSの不具合への対処、守らなければならない呼び出しの順番、変えてはいけない値など）
- 次の行を言い直すコメント、不具合の経緯、ライブラリの一般的な動き方の説明は書かない。経緯と変えた理由はcommit messageに書く
- 前例のコメントに倣うときも、前例にある分だけにとどめる
- 変更で正しくなくなったコメントは消すか直す

## テスト

- テストはSwift Testing（`import Testing`）で書く
- APIレスポンスのfixtureは`Packages/SciaCore/Tests/SciaCoreTests/Fixtures/`に置く。実サーバーのレスポンスを使う場合は、個人を特定できる情報を置き換える
- 変更した処理を差し替え、差し替えたものの呼ばれ方や返した値を確かめるだけのテストは書かない。変更した処理そのものを通らないので、壊れても落ちないため
- 決め打ちの文言を直すだけの修正には、直した文字列を書き写して比べるテストを足さない。テストを書く前に、どんな取り違えや退行を止めるかを一文で言えるか確かめ、言えなければ書かない。読み戻し、分岐、計算が絡む修正では、先に失敗するテストを書く
- 落ちたときに要る状態が失敗のメッセージに出ない画面は、状態ダンプ（`AppDependencies.stateDumps`）を登録するか足す
- テストは実際の時間や今の時刻に頼らせない。時間をおく処理には`SciaTesting`の手で進める`Clock`（`TestClock`）を渡し、`clock.advance(afterSleeping: 待ちの長さ)`で起こしたい待ちを長さで指す。ほかの処理は門（`Gate`）か条件（`waitUntil`）で待ち、`Task.yield`で譲って待たない。増えていく件数は`==`ではなく`>=`で待ってから`#expect`で確かめる。日時は決まった値で作る。アニメーションは層の時計（`LayerClock`）、毎フレーム進める動きは手で送るコマ（`ManualFrameSource`）で進める。止めたあとに何も起きないことは、時間を待たずに、走り終えていない処理の数や予約が残っていないことで確かめる
- 実物のコーデックやファイルの書き出しのように、かかる時間を差し替えられない処理のテストは、`.timeLimit`ではなく`.stallLimit`を付け、段階が進むたびに`StallProgress.current`の`note`で伝える。テスト全体の時間で見ると、ほかのビルドと重なってシミュレーターのコーデックが100倍以上遅くなった回に、固まっていないのに落ちるため
- テストで作る一時ファイルと設定の保存先（`UserDefaults(suiteName:)`）は、`SciaTesting`の`TestScratch`で作り、テストかスイートに`.scratch`を付ける。裏に回った状態は`whileInBackground`で囲んで作る
- `TimelineStore`に状態を足すときは、ストアのプロパティではなく`TimelineStore.State`に足す

## Git

- Codexで実装を始めるときは、現在のworktreeの`git symbolic-ref --quiet --short HEAD`を確認する。detached HEADなら、同じHEADに変更目的を表す`feat/`、`fix/`、`chore/`などのbranchを作ってから作業する。質問・調査だけでは作らない
- Codexで新しいworktreeを作る依頼では、アプリの`create_worktree`を使い、返されたworkspaceで作業する。既存worktreeでの続きは移動しない。新しいworktreeの`Config/Local.xcconfig`と`Config/CacheLocal.xcconfig`がない場合は、`git worktree list`で確認した元のcheckoutに存在するものだけコピーする。既存ファイルは上書きせず、署名やキャッシュの値をソースへ書き込まない
- Codexの`make build`、`make check`、`make test`は`exec_command`でそのworktreeを`workdir`に指定する。長い処理は返された`session_id`を`write_stdin`で終了まで待ち、終了コードと出力を確認する。`make check`と`make test`の振り分け・simの貸し借りはClaudeと共通で、別のキューを作らない
- 作業branchが`claude/epic-feistel-987485`のようにランダムな名前なら、作業を始めたら最初に`git branch -m`で`claude/fix-profile-open-race`のような名前へrenameする。`claude/`は残し、その後ろを種別と中身の分かる名前にする
- commit messageはConventional Commitsで書く。将来git-cliffでリリースノートを自動生成し、`feat:`（使う人に見える機能の追加）、`fix:`（使う人が遭遇する不具合の修正）、`perf:`（使う人が体感する性能の改善）だけを使う人向けの変更として載せる。開発のための変更（チューニングパネル、違和感レポート、検証ハーネス、ビルドやlintの設定など）は、`feat(dev):`、`fix(dev):`のようにdev scopeを付けてリリースノートから外し、使う人向けの変更とは別のcommitに分ける
- pushはユーザーが行う（`make scheduled-push`で入れた毎朝の自動pushを含む）。agentはcommitまでで止め、pushやpush承認の依頼はしない
- mainへは、ユーザーが`merge-to-main`スキルを明示的に起動したときだけ、`.agents/skills/merge-to-main`の手順で入れる。agentからは起動しない。共通の`tidy-ff-merge`は、`make check`と`make test`を通さないので使わない。mainは`make hooks`のhookが、`make check`と`make test`の両方が通った中身のcommitにしか動かさない
- worktreeの中では、fixup commitを作ることも、`rebase --autosquash`で元のcommitへまとめることも、確認なしで行ってよい。後ろに載ったユーザーのcommitのhashが作り直されても構わない
