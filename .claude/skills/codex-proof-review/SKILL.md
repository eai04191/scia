---
name: codex-proof-review
description: SciaCoreの変更を、Codexに使い捨ての複製で実際に動かして確かめさせるレビュー。変更が安全だと言える前提の事実を見つけ、失敗するテストで反証を探す。Packages/SciaCoreに変更があるとき、pr-readinessのCodexレビューと並べて走らせる。「証明つきでレビューして」と頼まれたときにも使う。
---

# 証明つきのCodexレビュー

読むだけのレビューは、もっともらしい指摘と見落としを区別できない。このレビューでは、変更が安全だと言える前提の事実を1つか2つ見つけさせ、それを`swift test`で実際に動かして確かめさせる。過去のcommitで試したとき、読むだけのレビューが見逃した不具合をこの方法だけが当て、すべての指摘に失敗するテストが付いていた。

やり方はpstackのblast-radius（Lauren Tan、MIT License）をもとにしている。

## 使う場面

- `git diff --name-only <review-from>`と`git status --short`に`Packages/SciaCore/`が含まれるとき。pr-readinessの「Codexレビュー」と同じときに、同じ`<review-from>`に対して、並べて走らせる
- アプリ側（`App/`）だけの変更には使わない。証明にシミュレーターが要り、ほかのスレッドと端末を取り合うため。対象外の理由を報告に1行で書く

## 手順

1. pr-readinessと同じ方法で、比較元のbase branch、merge-base、`<review-from>`を決める
2. 複製を作る。複製は作業ツリーの外に置き、Codexが書くテストやビルドの成果物で作業ツリーを汚さないようにする

   ```bash
   dir="$(mktemp -d)/copy"
   .claude/skills/codex-proof-review/make-copy.sh "$dir"
   ```

   `make-copy.sh`は、HEADに未commitの変更と未追跡のファイルを足した状態を再現する。このリポジトリのbranchを書き換えないよう、remoteは外してある
3. 下の「Codexへの指示」を一時ファイルに書き、複製の中でCodexを走らせる。証明のテストを書いて実行させるため、sandboxは`workspace-write`にする。`workspace-write`は既定でネットワークを止めるので、Mastodonのソースを読めるよう`network_access`を開ける。数分かかるので、バックグラウンドで走らせる

   ```bash
   gh_empty="$(mktemp -d)"
   (cd "$dir" && env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$gh_empty" codex review -c sandbox_mode='"workspace-write"' -c sandbox_workspace_write.network_access=true -c model='"gpt-6.1-sol"' -c model_reasoning_effort='"high"' - < <prompt-file> > <out-file> 2> <log-file>)
   rm -rf "$gh_empty"
   ```

   ネットワークを開けると、Codexはこのユーザーの資格情報で外部に届きうる。`workspace-write`はホームの読み取りを止めないので、remoteを外しても、`gh`のログイン情報などは読める。そこで`gh`の設定を空のディレクトリに向け、トークンの環境変数も外して、`gh`をログインしていない状態にする。ソースは認証の要らない`curl`で読ませる。これは、うっかり認証つきで読み書きするのを防ぐもので、隔離ではない。資格情報のファイルを直接読めば届くことは残る。外部に書き込まないことは、指示で縛る

   pr-readinessと同じく、結果はstdoutの`<out-file>`だけを読み、`<log-file>`は失敗したときだけ見る。`codex`が失敗したら、ほかの手段で代わりをせず、エラーを示して未確認とする
4. 指摘を扱う。pr-readinessのCodexレビューの指摘とまとめて、重なるものは1つにする
   - 証明のテストが付いた指摘は、テストが変更の意図どおりの前提を試しているかを確かめる。正しければ確かめ済みとして扱い、テストは作業ツリーのテストに書き直して取り込む（複製のファイルをそのままコピーしない）
   - 証明のない指摘は、pr-readinessと同じく、手元で本当に起きると確かめたものだけ相手にする
5. 複製を消す（`rm -rf "$(dirname "$dir")"`）。証明の出力は`<out-file>`に残っている

## Codexへの指示

`<base>`、`<merge-base>`、`<review-from>`、変更の意図をうめて、そのまま渡す。

````markdown
Review the code changes against the base branch '<base>'. The merge base commit is <merge-base>. Run `git diff <review-from>` and `git status --short` to inspect the changes to review, including uncommitted and untracked files. Changes before <review-from> were already reviewed; read them only as context. Provide prioritized, actionable findings.

## 変更の意図

<ユーザーの依頼の要約、受け入れ条件、設計判断とその理由>

## レビューの進め方

このディレクトリは使い捨ての複製で、何を書いてもよい。ネットワークは公開の情報を読むためだけに使い、外部には何も書き込まない（issue、PR、push、APIへの書き込みをしない）。`Packages/SciaCore`はSwiftPMのパッケージで、そのディレクトリで`swift test`（`--filter`で絞れる）が動く。本番のソースは書き換えない。証明のテストは`Packages/SciaCore/Tests/SciaCoreTests/`の下に、名前の先頭を`Proof`にしたファイルで置く。

差分の外で、この変更が壊すものを探す。呼び出し元を並べることが目的ではない。grepで見えない壊れ方を探す。

1. 変更を読む。差分、足した・変えた・消したシンボル、差分には書かれていないが変わった振る舞いまで含める
2. 変更が安全だと言える前提の事実を見つける。危なそうに見える変更の多くは、1つの事実（たとえば「このAPIは、続きがないときだけlimitより少ない件数を返す」）に支えられている。その事実を見つけることに時間を使い、可能性の長い一覧は作らない
3. grepが届かないところを見る。呼んでいるライブラリやOSのAPIの実際の振る舞い、Mastodonのサーバーの実装（`curl -sfL https://raw.githubusercontent.com/mastodon/mastodon/main/<path>`で読める。`gh`はログインしていない）、処理が走る順番と並行性、APIが返すJSONの形を確かめる
4. 前提の事実を、実際のコードを呼ぶテストで確かめる。テストを走らせ、出力を貼る。反証できたら、それが指摘になる
5. それぞれの事実をどこまで確かめたかを書く: 主張しただけ／行を示した／起こりえないことを順にたどって示した／テストで動かした

各指摘には、壊れ方、`file:line`、起こりやすさと影響、証明のテストのファイル名と出力を書く。確かめて問題がなかったことは、別に短く並べる。呼び出し元やAPIを作り話にしない。探して何も見つからなかったことも答えになる。
````
