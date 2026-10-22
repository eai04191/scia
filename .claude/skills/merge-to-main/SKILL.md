---
name: merge-to-main
description: sciaの作業branchを、ローカルのmainへ安全に入れる。残タスクや同意を取っていない項目がないかを確かめ、mergeに適切な単位かを判断し、まだ通っていないmake checkとmake testだけを走らせてから、fast-forwardで入れ、archiveしてよいかを伝える。「mainにマージして」「mainに入れて」「整理してmainにff mergeして」など、mainへ入れる依頼のすべてで使う。pushとGitHub上のPRのmergeには使わない。Use for every request to merge or land a branch into the local main in scia.
---

# Merge to Main

作業が落ち着いたところで、作業branchをローカルのdefault branch(以下target)へ入れるまでを、1回の依頼で済ませる。止まるのは、ユーザーに決めてもらうことがあるときと、安全に入れられないときだけにする。pushはしない。

targetは、指定がなければ`git symbolic-ref --short refs/remotes/origin/HEAD`のbranch名(例: `main`)。比較にはremoteではなくローカルのtargetを使う。

## 1. 残タスクと、同意を取っていない項目を確かめる

何かを変える前に、このthreadの会話全体を見直して、次を探す。

- 明示的な残タスク: ユーザーが頼んだのに済んでいないこと、途中で後回しにしたこと、直さずに報告した指摘、提案しただけでまだ始まっていない別のセッションのタスク
- 同意を取らずに仮で進めた項目: agentの判断で決めた仕様、文言、既定値、範囲の線引きのうち、ユーザーが決めるべきなのに確かめていないもの
- 残すべきなのに残していない判断: このthreadでユーザーが決めたのに、docsやAGENTS.mdなどプロジェクトの指示に書いていないこと。まだ決まっていない案や、agentが調べただけのことは含めない
- 作業branchの未commitの変更: 何の変更か分からないもの、作業の途中のもの

1つでも見つかったら、ここで止める。項目ごとに、何が残っているか、agentの推奨とその理由を書き、ユーザーに明示してもらうか、同意を取る。答えをもらって片付けたら、手順1からやり直す。見つけたものを、確認せずに直したりdocsに書き足したりしない。

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

## 3. checkとtestを通す

作業branchのworktreeで`Tools/check-stamp.sh missing HEAD`を実行し、出たもの（`make check`、`make test`）だけを、出た順に走らせる。何も出なければ、同じ中身で通っているので飛ばす。整理やrebaseで中身が変わらなければ、前に通した結果がそのまま使われる。同じworktreeで同時に走らせるとDerivedDataを取り合うので、順に走らせる。

- `make test`の端末は、このthreadで使うよう指示された端末にする。指示がなければ、ユーザーに聞く
- 走らせる前に、作業ツリーに未commitの変更がないことを確かめる。走らせている間も、ファイルを変えない
- 落ちたら、落ちたテストと作業branchの変更を読んで、原因を決める
  - 作業branchの変更が原因なら、作業branchで直してcommitし、手順2の5からやり直す
  - 作業branchの変更が触れていないテストなら、一度だけ走らせ直す。通れば続け、たまに落ちるテストとして報告に書く。また落ちたら、mergeせずに報告する。`Tools/check-stamp.sh missing <targetのSHA>`で、targetの中身では通っていたかも添える
  - 直すのに、仕様や挙動の判断が要るなら、mergeせずに報告する

## 4. fast-forward mergeする

- targetがworktreeでcheckoutされている場合: `git -C <そのworktree> merge --ff-only <作業branch>`
- checkoutされていない場合: `git fetch . <作業branch>:<target>`(fast-forwardでなければ失敗する)

`make hooks`のhookが入っていれば、`make check`と`make test`の両方が通っていない中身は、ここで拒否される。拒否されたら、手順3のあとに中身が変わっていないかを確かめて報告する。

mergeしたら、次を報告する。

- mergeしたcommitの一覧(`git log --oneline <mergeの前のtarget>..<target>`)
- pr-readinessの判定
- `make check`と`make test`の結果（走らせたか、前の結果を使ったか）と、使った端末。走らせ直して通ったテストと、直したもの
- どのcommitをどれにまとめたか。まとめなかった場合はその旨。整理前後で差分がないこと
- conflictを解決した場合は、どのファイルをどう解決したか
- 元のHEADのSHA。rebaseした場合はrebase前のHEADのSHAも

## 5. archiveについてコメントする

手順1で確かめたことに加えて、手順2から4の間に出たものを見直す。

- 報告だけして直していないこと（たまに落ちるテストなど）
- 片付け: プロジェクトの指示が置き場所を決めている引き継ぎのメモ（`.handoff/`）で、消すべきものが残っていないか。このセッションが始めた別のセッションが、まだ動いていないか
- このmergeの外の変更: 別のリポジトリへのcommitなど、ユーザーが後で扱う必要があるもの

どれもなければ「archiveしてよい」と書く。あれば、archiveの前に片付けるものと、閉じても困らないものに分けて挙げる。見つけたものは、確認せずに直したりdocsに書き足したりしない。
