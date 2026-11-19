# Codexでの実行

## 前提のbranchと作業状態

- `after:<ID>`はCodexのチャットID。`mcp__codex_app__list_threads`でそのIDの`cwd`と`hostId`を読み、必要なら`mode: "history"`のページをたどる。チャットの要約やタイトルをbranch名と見なさない
- 現在のMac上の`cwd`で`git -C <cwd> symbolic-ref --quiet --short HEAD`を走らせ、`git -C <cwd> rev-parse --path-format=absolute --git-common-dir`が自分と同じであることを確かめる。detached HEAD、別のリポジトリ、別のホストなら、前提のローカルbranchを解決できないので止めて報告する
- 解決したbranchは`git show-ref --verify refs/heads/<branch>`でも確かめる。`after-branch:<branch>`ならチャット参照は不要
- 終了コード5のときは`mcp__codex_app__wait_threads`に前提のID・hostIdと`timeoutMs: 0`を渡し、現在も実行中かを確認する。実行中と確認できた場合だけ並び直す
- CLIなどチャット管理ツールがない環境では`after-branch:`を使う。`after:`のIDをbranch名へ読み替えない

## 列の起動と待機

作業branchのworktreeを`workdir`に指定し、`exec_command`で`Tools/merge-queue.sh run <前提のbranch>...`を起動する。`yield_time_ms: 1000`程度で戻し、返された`session_id`を保存する。

- `session_id`が返ったら`write_stdin`で終了まで待つ。同じターンで待ち、キューに並んだだけで完了としてターンを返さない
- 各呼び出しの待機は60秒以下にし、待っている間も必要な進捗を伝える。`functions.exec`自体がcell IDを返した場合は、まず`functions.wait`でその呼び出しを完了させる。cell IDとシェルの`session_id`は別物
- 終了時の`exit_code`と最後の出力を読み、共通手順の「終わったら」へ進む。出力が長いときはファイルに保存して読んでよいが、パイプの終了コードをキューの終了コードと取り違えない
- 中断した場合は`Tools/merge-queue.sh status`、作業branchとmainのHEAD、実行セッションの状態を確かめてから再開する。動いている同じbranchを二重に並べない

## 完了時のタイトル

Codexアプリでは`mcp__codex_app__list_threads`で現在のチャットのタイトルを読み、`mcp__codex_app__set_thread_title`へ新しいタイトル全体を渡す。現在のチャットは`threadId`を省略できる。チャットIDが分からず、同じcwdのチャットが複数あるときは、タイトルを推測して変更しない。CLIなどタイトル管理ツールがない環境では、共通手順の完了報告を返せばよい。
