---
name: core-separation-check
description: SciaCoreとApp/Sourcesの分け方を、App/Sourcesを知らないsessionにAppKitのMac版を作らせて確かめ、見つかった漏れを別のsessionにSciaCoreで直させ、Mac版で直ったかを確かめさせる。親のsessionが2つの子のsessionの間を取り次ぐ。ユーザーが/core-separation-checkで起動したときだけ使う。
argument-hint: "[base:<Mac版のbranch>]"
disable-model-invocation: true
---

# SciaCoreの分け方を確かめる

このskillを起動したsession（親）は、2つの子のsessionの間を取り次ぐ。親は実装しない。

- X: AppKitのMac版を作る。App/Sourcesを読まず、iOS版の作りを何も知らないまま、SciaCoreだけで作れるかを確かめ、困ったことを記録する
- Y: Xが困ったことのうち、ユーザーが直すと決めたものを、SciaCoreとApp/Sourcesで直す

確かめたいのは「SciaCoreの公開APIと説明だけで、別のUIが正しく作れるか」なので、XがiOS版の作りを知った時点で、そのXでは確かめられなくなる。取り次ぎの誤りは取り返せないので、下の決まりを1つずつ守る。

XとYは、起動のたびに新しく作る。前の回のsessionに頼まない。引数（`$ARGUMENTS`）の`base:`には、Xを始めるMac版のbranchが入る。

## 決まり

### branch

- X、Y、親は、それぞれ自分のworktreeとbranchで作業する。X、Yは`use_worktree: true`で始める
- 親は、XとYのworktreeで、手順5の取り込みのほかは、git（commit、merge、reset、checkout、rebaseなど）もファイルの変更もしない。読むのは`git -C <worktree> log`、`git show <branch>:<path>`など、変えない操作だけ
- Yは、Xのbranchとworktreeに触らない。XはYのbranchに触らない
- 2つのbranchがつながるのは、親がYのbranchをXのbranchへmergeするときだけ。XとYはmergeしない
- Yのbranchをmainへ入れるのは、ユーザーがYのsessionで`/merge-to-main`を起動したときだけ
- Mac版のbranchはmainへ入れない

### 名前

- `start_session`の`title`は「X: 」か「Y: 」で始め、続けて中身を書く（「X: Mac版に通知とスレッドを足す」）。`name`と`branch_name`は`x-`か`y-`で始める（`x-mac-notifications`）。サイドバーやbranchの名前から、どちらのsessionかを見分けられるようにするため

### 伝えること

- Xへは、SciaCore、docs、AGENTS.md、X自身のMac版のコードと記録から分かることしか伝えない。App/Sourcesのパス、iOS版の型や関数の名前、iOS版がどう作っているか、Yがなぜそう直したかのApp側の事情は、どれも伝えない
- Xに送る文は、送る前に読み直し、上のどれかが入っていたら消す。Yの報告の文をそのまま貼らない
- Xの記録（`Mac/FINDINGS.md`）に、iOS版の事実を書かせない。Xの推測を確かめた結果は、Yへのbriefとユーザーへの報告にだけ書く
- 子が「〜しますか？」と聞いてきたら、答えをそのまま返す前に、それを誰がやるべきかを決まりに照らす。Xのbranchの作業ならXに、SciaCoreの作業ならYに頼む。聞いてきたsessionが違えば、そのsessionには「それは親が別のsessionに頼む」とだけ返す

### 子の報告を読む

- 子のturnが終わったら、通知の冒頭だけで判断しない。`mcp__ccd_session_mgmt__list_events`で報告の全文を読み、そのbranchを`git log`で読み、記録があれば読む
- ユーザーが子のsessionで直接進めたturnの通知は、親に届かない。ユーザーに状況を答える前と、次の手順へ進む前に、子のsessionの`list_events`と`git log`で最新の状態を確かめる

## 手順

### 1. Xを始める

- Xを始めるbranchを決める。`base:`があればそれ、なければmain。`base:`のbranchを使えるのは、mainにないcommitが、Xのsessionのcommitと、親が手順5で取り込んだmergeのcommit（とそれで入ったYのcommit）だけで、`Mac/FINDINGS.md`にiOS版の事実がないときだけ。どちらかが分からなければ、ユーザーに聞く
- `mcp__ccd_session__start_session`を、`initiation: "user_asked"`、`context: "fresh"`、`use_worktree: true`、`source_branch`に決めたbranchで呼ぶ。`fork`にしない（親の会話にApp/Sourcesの中身が入っていることがあるため）
- briefは下の「Xへのbrief」で書く。親が気づいたSciaCoreの怪しいところ（見せ方に寄った名前の型など）は書かない。Xの見方を寄せてしまうため

### 2. Xの報告を受ける

1. 報告の全文、Xのbranchの`git log`、`Mac/FINDINGS.md`を読む
2. Xが推測と書いたものは、親がApp/Sourcesを読んで確かめる。親の仕事なので、ユーザーに聞かない。結果はXには伝えない
3. 見つかったものを、直す価値の大きい順に並べ、どれをYに直させるかをユーザーに聞く。項目ごとに、何が困るか、App側で確かめた事実、推奨を書く

### 3. Yを始める

- `mcp__ccd_session__start_session`を、`initiation: "user_asked"`、`context: "fresh"`、`use_worktree: true`で、mainから始める
- briefは下の「Yへのbrief」で書く。Xの記録の該当する項目と、手順2で確かめたApp側の事実を入れる
- 手順6から戻ってきたときは、この回のYに頼む

### 4. Yの報告を受ける

1. 報告の全文と、Yのbranchの`git log main..<Yのbranch>`を読む。Yのbranchだけが変わり、Xのbranchが変わっていないことを`git -C <Xのworktree> log`で確かめる
2. `make check`、`make test`、`pr-readiness`が通っていなければ、Yに直させる
3. Yが聞いてきたことは、決まりの「伝えること」に照らして振り分ける

### 5. XのbranchへYの変更を取り込む

1. Xのsessionが動いていないことを`mcp__ccd_session_mgmt__get_session`で確かめる。動いていれば、止まるまで取り込まない
2. Xのworktreeに未commitの変更がないことを`git -C <Xのworktree> status --short`で確かめる。あれば取り込まずにユーザーに報告する
3. `git -C <Xのworktree> merge --no-edit refs/heads/main`、続けて`git -C <Xのworktree> merge --no-edit refs/heads/<Yのbranch>`で取り込む。mainを先に取り込むのは、前の回のYがmainへrebaseされて入ったとき、Xに残る前のYのcommitとmainのYのcommitの中身をそろえ、今の回のYのmergeの基点をmainにするため。どちらかでconflictしたら`git -C <Xのworktree> merge --abort`で戻し、どのファイルかをユーザーに報告する。親はconflictを解決しない
4. Xのsessionに`SendMessage`で、下の「Xへの確認の依頼」を送る。送る前に、決まりの「伝えること」で読み直す

### 6. Xの報告を受けて、ユーザーに伝える

1. 報告の全文、Xのbranchの`git log`、`Mac/FINDINGS.md`を読む
2. ユーザーに、Yが直した項目ごとに、Mac版で直ったか、Mac版のコードがどれだけ減ったか、残ったものを伝える。Mac版の起動の確認がまだなら、Xのsessionで確かめてもらうよう書く
3. 残ったものを直すなら手順3へ。終えるなら、Yのsessionで`/merge-to-main`を起動してもらうよう書く。次の回は、Yがmainに入ってから、この回のXのbranchを`base:`にして起動してもらう（mainに入ったこの回のYと、その後のmainの変更は、次の回の手順5でmainを先に取り込むときに入る）

## Xへのbrief

次を入れる。

- やること: Mac版を作る。画面の骨格、タイムライン、入力はAppKitで作る。中に入力もスクロール位置の精密な制御も持たない表示の部品は、SwiftUIで作って載せてよい。UIKitとMac Catalystは使わない（UIKitのコードがそのまま動き、分け方を確かめられないため）。今回作る動線をユーザーの言葉で書く。続きから始めるなら、今あるMac版のどこから何を足すか
- 読んでよいもの: SciaCoreのソース、公開API、テスト、`docs/`、`AGENTS.md`、自分のbranchのMac版のコードと記録。App/Sourcesは、grep、ファイルを開く、subagentに読ませる、のどれもしない。App側を見ないと分からなかったことは、それ自体を記録する
- SciaCoreは変えない。変えたくなった箇所は記録にとどめる
- ターゲットは`project.yml`に足し、`make generate`で作る。署名とbundle IDは`macos-app-dev`のskillに従う。`Config/Local.xcconfig`は元のcheckoutからコピーする
- Macでアプリを`open`したり、画面を操作したりしない。ビルドが通るところまでを確かめ、起動と動線の確認は手順を示してユーザーに頼む
- commitは区切りごとに自分のbranchへ。pushとmergeはしない（ほかのbranchの変更は親が取り込む）。ほかのbranchとworktreeに触らない。取り込まれたmergeのcommitの、App/Sourcesの差分は見ない
- 記録: 困ったことを1件ずつ、`Mac/FINDINGS.md`に次の分類で書く。各件に、SciaCoreのどこか、何に困ったか、どう回避したか、Mac版で書き直した量を書く。推測で分類したものは推測と分かるように書く
  - A: SciaCoreにUI固有の処理が入っている
  - B: App側に、本来SciaCoreに置くべきロジックが残っている（Macで同じものを書き直す羽目になった）
  - C: SciaCoreのAPIがUIKitの使い方に合わせた形で、使えるが回りくどい
  - D: AppKit固有なので、Mac側で書くのが正しい
- 報告: 最初の一文で結論を言い、A〜Dの件数と、直す価値が大きいと思うものを上から数件、何が困るかの言葉で書く（型名や関数名だけで書かない）。ユーザーに頼む確認の手順を添える

## Yへのbrief

次を入れる。

- 直す項目: Xの記録の項目の見出しと中身（`git show <Xのbranch>:Mac/FINDINGS.md`で読めることも書く）と、親がApp/Sourcesで確かめた事実
- やること: SciaCoreに置き、App/Sourcesをそれを使う形に置き換える。iOSの挙動は変えない。決まりはSciaCoreのテストで確かめる
- 終わりの形: `make check`と`make test`が通り、`pr-readiness`がREADYで、変えた動線をシミュレーターで確かめてある
- 触ってよいのは自分のbranchとworktreeだけ。Mac版のbranchとworktreeは読むだけにし、mergeもcommitもしない。Mac版で確かめることは親が別のsessionに頼むので、それを提案しない
- 報告: 最初の一文で結論を言い、branchの名前を`refs/heads/…`で書き、何が防げるようになったかを型名だけでなく言葉で書く

## Xへの確認の依頼

次だけを書く。

- 直した項目: Xの記録の見出しで書く（「B1とB5」など）
- 取り込んだもの: 親がYのbranchを、Xのbranchへmergeしたこと（mergeのcommitのSHA）。App/Sourcesの差分は見ないよう添える
- 頼むこと: 直した項目の回避をやめてSciaCoreの新しい部品で置き換え、Mac版のビルドを通し、`Mac/FINDINGS.md`に結果（直ったか、減った量、新しく困ったこと）を書き足してcommitする。App/Sourcesを読まない約束は変わらない。起動の確認は手順を示してユーザーに頼む

Yがどう直したか、新しい部品が何を守るかは書かない。Xが新しい部品の説明だけで使えるかを確かめるため。
