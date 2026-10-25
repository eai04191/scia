---
name: merge-to-main
description: sciaの作業branchを、ほかのスレッドと1つずつ、ローカルのmainへ安全に入れる。残タスクや同意を取っていない項目がないかを確かめ、mergeに適切な単位かを判断してから、Tools/merge-queue.shの列に並べる。番が来たら最新のmainへrebaseし、まだ通っていないmake checkとmake testだけを走らせてfast-forwardで入れ、archiveしてよいかを伝える。ユーザーが/merge-to-mainで起動したときだけ使う。
argument-hint: "[端末] [after:<セッションID>...]"
disable-model-invocation: true
---

# Merge to Main

作業が落ち着いたところで、作業branchをローカルのdefault branch(以下target)へ入れるまでを、1回の依頼で済ませる。止まるのは、ユーザーに決めてもらうことがあるときと、安全に入れられないときだけにする。pushはしない。

mainへ入れる処理（rebase、`make check`、`make test`、fast-forward）は、`Tools/merge-queue.sh`の列を通して、どのスレッドからでも1つずつ走らせる。順番は問わず、ユーザーが前提に指定したスレッドのbranchがmainに入るまでは、番を待つ。

targetは、指定がなければ`git symbolic-ref --short refs/remotes/origin/HEAD`のbranch名(例: `main`)。比較にはremoteではなくローカルのtargetを使う。

引数（`$ARGUMENTS`）には、`make test`に使う端末と、前提のスレッドのセッションID（`after:local_…`、複数可）が入る。

## 1. 残タスクと、同意を取っていない項目を確かめる

何かを変える前に、このthreadの会話全体を見直して、次を探す。

- 明示的な残タスク: ユーザーが頼んだのに済んでいないこと、途中で後回しにしたこと、直さずに報告した指摘、提案しただけでまだ始まっていない別のセッションのタスク
- 同意を取らずに仮で進めた項目: agentの判断で決めた仕様、文言、既定値、範囲の線引きのうち、ユーザーが決めるべきなのに確かめていないもの
- 残すべきなのに残していない判断: このthreadでユーザーが決めたのに、docsやAGENTS.mdなどプロジェクトの指示に書いていないこと。まだ決まっていない案や、agentが調べただけのことは含めない
- 作業branchの未commitの変更: 何の変更か分からないもの、作業の途中のもの

見つけた残タスクのうち、ユーザーに決めてもらうことを含まず、依頼の範囲でagentが済ませられるもの（AGENTS.mdがagentにやらせている、シミュレーターでの動きや見た目の確認、録画、テストの追加など）は、聞かずに済ませ、手順1からやり直す。確かめずに入れるかどうかを、選択肢にしない。

それ以外が1つでも見つかったら、ここで止める。項目ごとに、何が残っているか、agentの推奨とその理由を書き、ユーザーに明示してもらうか、同意を取る。答えをもらって片付けたら、手順1からやり直す。決めることを含むものを、確認せずに直したりdocsに書き足したりしない。

## 2. mergeに適切な単位かを判断する

1. `git worktree list`で、targetがどのworktreeでcheckoutされているかを調べる。そのworktreeに未commitの変更がある場合は、止めて報告する
2. `git merge-base --is-ancestor <target> HEAD`でfast-forwardできるか調べる。できなければ、rebase前のHEADのSHAを控えてから`git rebase <target>`で載せ直す。conflictしたら、両側のcommitの意図を読んで両方の変更を残すよう解決し、`git rebase --continue`で続ける。両側が同じ規則や挙動を別の方向に変えていて、どちらを優先するか決める必要がある場合は、`git rebase --abort`で戻して報告する
3. `git rev-parse <target>`でtargetのSHAを控える。以降はbranch名ではなくこのSHAを使う
4. `git log --reverse --format='%h %s' <targetのSHA>..HEAD`と差分全体を読み、mainに入れる単位として次を満たすかを判断する
   - 目的がひとまとまりで、関係のない変更が混ざっていない
   - 途中で終わっていない。機能の半分だけ、テストのない修正、呼び出し側を直していない変更などを入れない
   - 入れたあとのmainで、使う人に見える挙動が中途半端にならない

   満たさなければ、mergeせずに止める。何が合わないかと、分け方や足りないものの推奨を書く
5. `pr-readiness`の自己判定モードを通す。比較元はtargetのSHAにする。直前の自己判定から差分が変わっていなければ、その結果を使う。READYにならなければ、mergeせずに理由を報告する
6. 履歴を、変更目的ごとの論理単位に整理する。ユーザーには確認しない。整理が要らなければ飛ばす
   - targetにまだ入っていない機能への手直し(`fix:`など)は、その機能のcommitへまとめる。実装とリファクタリング、目的が別のcommitは、まとめない
   - まとめたcommitのmessageは、途中経過ではなく最終的な変更内容を、プロジェクトの言語とprefixで書き直す
   - 対話的なrebase(`-i`)は使わない。元のHEADのSHAを控え、1つにまとめるだけなら`git reset --soft <targetのSHA>`して`git commit`する。複数に分けるなら、`git reset --hard <targetのSHA>`のあと、まとまりごとに`git cherry-pick --no-commit <commit>...`を古い順に実行してから`git commit`する
   - commitには、上位指示または実行環境で指定された`Co-authored-by` trailerを`--trailer`で渡す
   - `git diff <元のHEAD> HEAD`が空であることを確かめる。差があれば`git reset --hard <元のHEAD>`で戻して報告する

## 3. 列に並ぶ

- `make test`の端末は、引数にあればそれにする。なければ、このthreadで使うよう指示された端末にする。どちらもなければ、ユーザーに聞く
- 引数の`after:`のセッションIDごとに、`mcp__ccd_session_mgmt__get_session`でそのスレッドのbranchを引く。引けなければ、並ばずに報告する
- 作業ツリーに未commitの変更がないことを確かめてから、作業branchのworktreeで`Tools/merge-queue.sh run '<端末>' <前提のbranch>...`をBashの`run_in_background`で起動する。並んだことを伝えて、ターンを終える。待っている間と走っている間は、作業ツリーを変えない。列は`Tools/merge-queue.sh status`で見られる

## 4. 終わったら

終了コードで分ける。どの場合も、出力の最後の部分を読んでから動く。

- 0（入れた）: 下の報告をして、手順5へ進む
- 2（未commitの変更がある）: 出力にあるworktreeの変更が何かを確かめて、報告する。片付けずに並び直さない
- 3（rebaseがconflictした）: 手順2の2のとおり、最新のtargetへrebaseして解決し、手順2の5からやり直してから、手順3で並び直す。どちらを優先するか決める必要がある場合は、並び直さずに報告する
- 4（`make check`か`make test`が落ちた）: 落ちたテストと作業branchの変更を読んで、原因を決める
  - 作業branchの変更が原因なら、作業branchで直してcommitし、手順2の5からやり直して並び直す
  - 作業branchの変更が触れていないテストなら、一度だけ並び直す。通れば、たまに落ちるテストとして報告に書く。また落ちたら報告する。`Tools/check-stamp.sh missing <targetのSHA>`で、targetの中身では通っていたかも添える
  - 直すのに、仕様や挙動の判断が要るなら、報告する
- 5（前提のbranchが、列にもmainにもないまま10分経った）: 前提のスレッドを`get_session`で引き、`isRunning`がtrueなら、まだ準備の途中なので並び直す。falseなら、並び直さずに、どのスレッドが入らないまま止まっているかを報告する
- 1（それ以外）: 出力を報告する

入れたら、次を報告する。

- 入れたcommitの一覧（スクリプトの出力の最後にある）
- pr-readinessの判定
- `make check`と`make test`の結果と、使った端末。出力に「走らせます」とあったものが走らせたもの、なかったものは前の結果を使ったもの。並び直して通ったテストと、直したもの
- どのcommitをどれにまとめたか。まとめなかった場合はその旨。整理前後で差分がないこと
- conflictを解決した場合は、どのファイルをどう解決したか
- 元のHEADのSHA。rebaseした場合はrebase前のHEADのSHAも

## 5. archiveについてコメントする

手順1で確かめたことに加えて、手順2から4の間に出たものを見直す。

- 報告だけして直していないこと（たまに落ちるテストなど）
- 片付け: プロジェクトの指示が置き場所を決めている引き継ぎのメモ（`.handoff/`）で、消すべきものが残っていないか。このセッションが始めた別のセッションが、まだ動いていないか
- このmergeの外の変更: 別のリポジトリへのcommitなど、ユーザーが後で扱う必要があるもの

どれもなければ「archiveしてよい」と書く。あれば、archiveの前に片付けるものと、閉じても困らないものに分けて挙げる。見つけたものは、確認せずに直したりdocsに書き足したりしない。
