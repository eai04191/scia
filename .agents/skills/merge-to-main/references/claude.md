# Claude Codeでの実行

## 前提のbranchと作業状態

- `after:<ID>`は、`mcp__ccd_session_mgmt__get_session`でそのスレッドのbranchを引く。ツールは`ToolSearch`で定義を読み込む。ローカルbranchの存在を`git show-ref --verify refs/heads/<branch>`で確かめる
- 終了コード5のときは、同じツールで`isRunning`を読む。trueなら並び直し、falseなら共通手順に従って報告する

## 列の起動と待機

作業branchのworktreeで`Tools/merge-queue.sh run <前提のbranch>...`をBashの`run_in_background`で起動する。並んだことを伝えてターンを終え、完了通知を受けたら出力と終了コードを読み、共通手順の「終わったら」へ進む。

## 完了時のタイトル

`mcp__ccd_session_mgmt__get_session`に`session_id: "self"`を渡して現在のタイトルを読み、`mcp__ccd_session_mgmt__set_session_title`に`session_id: "self"`と、新しいタイトル全体を渡す。どちらも`ToolSearch`で定義を読み込む。
