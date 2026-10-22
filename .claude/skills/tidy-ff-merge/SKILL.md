---
name: tidy-ff-merge
description: 作業branchのcommit履歴を整理してから、ローカルのdefault branchへfast-forward mergeする。「整理してmainにff mergeして」「rebaseして整理してマージして」「まとめてからmainに入れて」と頼まれたときに使う。pushとGitHub上のPRのmergeには使わない。Use when the user asks to tidy (squash/rebase) the current branch's commits and fast-forward the local default branch to it.
---

# Tidy FF Merge

作業branchの履歴を、変更目的ごとの論理単位に整理してから、ローカルのdefault branch(以下target)へfast-forward mergeする。pushはしない。

## 1. 対象を確定する

1. targetを決める。指定がなければ`git symbolic-ref --short refs/remotes/origin/HEAD`のbranch名(例: `main`)。比較にはremoteではなくローカルのtargetを使う
2. `git worktree list`で、targetがどのworktreeでcheckoutされているかを調べる。そのworktreeに未commitの変更がある場合は、止めて報告する
3. 作業branchに未commitの変更があれば、止めて報告する
4. `git merge-base --is-ancestor <target> HEAD`でfast-forwardできるか調べる。できなければ、rebase前のHEADのSHAを控えてから`git rebase <target>`で載せ直す。conflictしたら、両側のcommitの意図を読んで両方の変更を残すよう解決し、`git rebase --continue`で続ける。両側が同じ規則や挙動を別の方向に変えていて、どちらを優先するか決める必要がある場合は、`git rebase --abort`で戻して報告する
5. `git rev-parse <target>`でtargetのSHAを控える。手順2と4ではbranch名ではなくこのSHAを使う

## 2. 品質を判定する

`pr-readiness`の自己判定モードを通す。比較元はtargetのSHAにする。直前の自己判定から差分が変わっていなければ、その結果を使う。READYにならなければ、mergeせずに理由を報告する。

## 3. 整理の仕方を決める

`git log --reverse --format='%h %s' <target>..HEAD`の各commitを、変更目的ごとにまとめる。

- targetにまだ入っていない機能への手直し(`fix:`など)は、その機能のcommitへまとめる
- 実装とリファクタリングは、別のcommitのまま残す
- 目的が別のcommitは、まとめない
- まとめたcommitのmessageは、途中経過ではなく最終的な変更内容を、プロジェクトの言語とprefixで書き直す

ユーザーに確認せずに決めて、手順4へ進む。整理が不要なら、手順4を飛ばして手順5へ進む。

## 4. 履歴を作り直す

対話的なrebase(`-i`)は使わない。

1. 元のHEADのSHAを控える
2. 1つにまとめるだけなら`git reset --soft <targetのSHA>`して`git commit`する
3. 複数のcommitに分けるなら、`git reset --hard <targetのSHA>`のあと、まとまりごとに`git cherry-pick --no-commit <commit>...`を古い順に実行してから`git commit`する。conflictしたら、そのまとまりまでの変更を含むよう解決して続ける
4. commitには、上位指示または実行環境で指定された`Co-authored-by` trailerを`--trailer`で渡す
5. `git diff <元のHEAD> HEAD`が空であることを確かめる。差があれば`git reset --hard <元のHEAD>`で戻して報告する

## 5. checkとtestを通す

作業branchのworktreeで、整理したあとのHEADに対して、`make check`のあとに`make test SIM='<使う端末>'`を走らせる。同じworktreeで同時に走らせるとDerivedDataを取り合うので、順に走らせる。

- 端末は、このthreadで使うよう指示された端末にする。指示がなければ、ユーザーに聞く
- 走らせる前に、作業ツリーに未commitの変更がないことを確かめる。走らせている間も、ファイルを変えない
- どちらかが失敗したら、mergeせずに、失敗したテストと出力を報告する。このskillの中では直さない

## 6. fast-forward mergeする

- targetがworktreeでcheckoutされている場合: `git -C <そのworktree> merge --ff-only <作業branch>`
- checkoutされていない場合: `git fetch . <作業branch>:<target>`(fast-forwardでなければ失敗する)

`make hooks`のhookが入っていれば、`make check`が通っていない中身はここで拒否される。拒否されたら、手順5のあとに中身が変わっていないかを確かめて報告する。

## 7. 報告する

- pr-readinessの判定
- `make check`と`make test`の結果と、使った端末
- どのcommitをどれにまとめたか。まとめなかった場合はその旨
- mergeしたcommitの一覧(`git log --oneline <mergeの前のtarget>..<target>`)
- 整理前後で差分がないこと
- conflictを解決した場合は、どのファイルをどう解決したか
- 元のHEADのSHA。rebaseした場合はrebase前のHEADのSHAも
- このセッションをarchiveしてよいか（手順8）

## 8. archiveしてよいか判断する

会話全体を見直して、次を確かめる。

- やり残し: ユーザーが頼んだのに済んでいないこと、途中で後回しにしたこと、直さずに報告した指摘（依頼の範囲外のもの、ユーザーが決めること）、提案しただけでまだ始まっていない別のセッションのタスク
- 残すべき情報: この会話でユーザーが決めたのに、docsやプロジェクトの指示に書いていないこと。まだ決まっていない案や、エージェントが調べただけのことは含めない
- 片付け: プロジェクトの指示が置き場所を決めている引き継ぎのメモで、消すべきものが残っていないか。このセッションが始めた別のセッションが、まだ動いていないか
- このmergeの外の変更: 別のリポジトリへのcommitなど、ユーザーが後で扱う必要があるもの

どれもなければ「archiveしてよい」と書く。あれば、archiveの前に片付けるものと、閉じても困らないものに分けて挙げる。見つけたものは、確認せずに直したりdocsに書き足したりしない。
