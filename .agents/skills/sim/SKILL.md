---
name: sim
description: シミュレーター（Scia 1〜Scia 4。名指しすればScia iPad 1、Scia Duoなども）を、触る間だけこのworktreeに借りる。空きがなければ空くまで待ち、端末が替わっていたら設定を戻してビルドを入れ直す。シミュレーターを触る直前に毎回、またはユーザーが/simで起動したときに使う。
argument-hint: "[番号か名前]"
---

# シミュレーターを借りる

端末は4台しかないので、スレッドが4つより多くても回るよう、シミュレーターを触る間だけ借りて、触り終えたらすぐ返す。コードを書いたりビルドしたりしている間は持たない。貸し借りは`Tools/sim.sh`がworktreeごとに記録する。並行するスレッドはworktreeを分けるので、借り手はworktreeで表す。

引数（`$ARGUMENTS`）には、使う端末の番号（1〜4）か名前（`Scia iPad 1`、`Scia Duo`など）が入ることがある。ユーザーが特定の端末を指定したときと、iPadや画面を開閉するiPhoneでの見え方を確かめるときだけ渡す。

## 実行環境

- Claude Codeはシミュレーターのツールを使い、毎回`device`に借りた端末の名前を渡す
- Codexは`Tools/sim.sh axe '<端末>' <操作> <引数...>`でAXeを使う。`--udid`は渡さない。AXeがなければ`brew install cameroncooke/axe/axe`が必要と報告する。画像は`shot`の出力を`view_image`で開く
- Codexのコマンドは`exec_command`で起動し、返された`session_id`を`write_stdin`で終了まで待つ。1回の待機は60秒以下にする。Claude向けのBashのtimeout指定は使わず、待機時間とコマンドの終了を区別する
- 直接のsimctl・AXe操作を止めるhookは、Claude Codeの`.claude/settings.json`とCodexの`.codex/hooks.json`から同じ`Tools/sim-lease-guard.py`を呼ぶ。Codexのworktreeでは元のcheckout側のプロジェクト設定が参照される場合があるので、導入をmainへ反映したあと新しいセッションで`/hooks`の一覧にこのhookがあることを確認する。新しいhookが信頼待ちなら、ユーザーに`/hooks`で定義の確認と信頼をしてもらう。agentは信頼設定を書き換えない。hookの信頼前も貸し借りとラッパーの手順は守る

Codexでの入力例（座標は`dump`で確かめてから決める）:

```bash
Tools/sim.sh axe '<端末>' tap -x 200 -y 400 --hold 0.15
Tools/sim.sh axe '<端末>' swipe --start-x 200 --start-y 600 --end-x 200 --end-y 300 --duration 0.5
Tools/sim.sh axe '<端末>' draw 200,600 200,400 200,400.5 200,400 --duration 1
```

`tap`、`swipe`、`drag`、`draw`、`touch`、`type`、`key`、`key-sequence`、`key-combo`、`button`、`gesture`、`slider`、`hinge`、`rotate`、`describe-ui`、`displays`を使える。引数は`axe <操作> --help`で確認する。`draw`は点の列を通るドラッグに使う。操作後は`dump`で結果を確かめる。`type`はUSキーボードで入力できる文字に限られるため、投稿本文や日本語は共通手順のデバッグURLで入れる。

## 1. 借りる

シミュレーターを触る直前（確かめ、録画、`ONLY`を付けた`make test`、`Tools/sim.sh shot`・`dump`の前）に、`Tools/sim.sh acquire`を走らせる。番号を指定されたら`Tools/sim.sh acquire 'Scia <番号>'`、名前なら`Tools/sim.sh acquire '<名前>'`にする。

`SIM`も`ONLY`も付けない`make test`、`make check`、`make check-test`では借りない。入口が別のMacか手元の枠を選び、手元の枠で走るときは入口が借りて返すため（docs/test-dispatch.md）。

- 空きがなければ、空くまで待つ。ユーザーには聞かない。終了コード75で終わったら、もう一度走らせて待ち続ける。Bashのtimeoutは600000にする
- 以後、シミュレーターのツールの`device`と`Tools/sim.sh`には、出力の最後の行の端末を渡す。`ONLY`を付けた`make test`と`make sim-keyboard`は、借りている端末を自分で選ぶので`SIM`を渡さない

## 2. 状態で分ける

- `ready`なら、そのまま使う。ただしユーザーが手で触ったことはありうるので、確かめに要る設定は前提にせず、確かめる直前に入れる
- `claimed`なら、次をすべて行う
  - `Tools/sim.sh reset '<端末>'`を走らせる
  - このworktreeのビルドを入れる。`make check`か`make test`が通ったあとコードを変えていなければ、`DerivedData/checked/Scia.app`を入れる。`make test`はテストのたびに入れるので、`make test`だけなら要らない
  - 入れ終えたら`Tools/sim.sh ready '<端末>'`で記録する。途中で失敗したら記録しない。次に借りたとき`claimed`のまま読めて、やり直せるようにするため

## 3. 返す

触り終えたら、`Tools/sim.sh release`で返す。ターンを返す前にも必ず返す。次にまた触るときは、1から借り直す。

- 続けて長く使うときは、貸し出しが切れる前に`Tools/sim.sh acquire`を走らせ直して延ばす
- バックグラウンドで端末を使い続ける処理（`make test`、録画）の結果を待つ間は、返しておいてよい

## 4. 端末を触るときの決まり

- iPadと画面を開閉するiPhoneでの見え方は、`Scia iPad 1`、`Scia iPad 2`（iPad mini）、`Scia Duo`（iPhone Duo）で確かめる。`Tools/sim.sh acquire 'Scia iPad 1'`のように名指しして借りる。ログインしていない端末では`scia-debug://dummy-session`で入る
- iPadでは、アプリが画面の一部のウインドウで開く。`dump`の座標は画面の座標（タップと同じ）で、ウインドウの位置と大きさは`ウインドウ`の行の`枠`に出る
- `Scia Duo`は画面が2つあり、`simctl io`の`screenshot`と`recordVideo`は`--display`がないと失敗する。録画は`io recordVideo --display=primary`で撮る
- 端末に命令を送る`xcrun simctl`（`openurl`、`spawn`、`launch`、`install`、`io`など）は、直接呼ばずに`Tools/sim.sh ctl '<使う端末>' <操作> <引数...>`で送る。直接の呼び出しと、借りていない端末を指したシミュレーターのツールは、hook（`.claude/settings.json`、`Tools/sim-lease-guard.py`）が実行の前に止める。`list`と`get_app_container`のような、端末を変えない操作は直接呼んでよい。`Tools/sim.sh acquire`の出力の最後の行で借りた端末を読んでから、次のコマンドで送る
- 4台は同じアカウントでログインしているため、サーバー上の状態は共有される。読んだ位置は`api/v1/markers`でサーバーに保存され、起動時に読み込まれるので、別のスレッドがスクロールすると次の起動位置が変わる。投稿やブーストも、ストリーミングで他の端末に流れ込む。起動時の位置や新着の挙動を確かめるときは、他のスレッドの操作で結果が乱れていないか疑う
- 端末のクリップボードには、自分が`Tools/sim.sh ctl '<使う端末>' pbcopy`で入れたもの以外をペーストしない。DeviceHubの「Use Shared Clipboard」がオンだと、Macのクリップボードが端末へ書き込まれ、Universal Clipboardで届いたユーザーのiPhoneのコピーも入るため、投稿欄に貼ると仕事の内容が投稿される。`Tools/sim.sh acquire`は、借りた端末の同期を切ってクリップボードを空にする。投稿欄の本文と添付は、ペーストではなく`scia-debug://compose`の`text`と`media`で入れる。ペーストそのものを確かめるときは、貼る直前に`pbcopy`で中身を入れる
- 画面は、タップでたどらず`Tools/sim.sh ctl '<使う端末>' openurl '<URL>'`で開く。アプリの画面は`scia://`のURL（docs/app-url.mdの「開ける画面」）で開き、デバッグ版だけの画面と操作は`scia-debug://`（docs/debug-urls.md）で開く。`scia-debug://reset`（重ねた画面を閉じてホームに戻す）のあとに続けて送ってよい。閉じ終えてから開く。IDやハンドルは、ログインしているサーバー（stellaria.network）の公開API（`api/v1/accounts/lookup?acct=`、`api/v1/accounts/<ID>/statuses`）で調べる
- `Scia Scenario`は`make scenario-*`の専用の端末で、貸し借りしない。ほかの確かめには使わない
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- 貸し借りする端末は、メモリを減らすため、[simslim](https://github.com/MobAI-App/simslim)で写真以外の使わないサービスを止めている（`simslim on <UDID> --except photos`）。プッシュ通知、ユニバーサルリンク、iCloud、Spotlight、言語のデータの読み込みなどは、エラーを出さずに動かないことがある。こうした機能が動かないときは、Sciaの不具合と決める前に`simslim status <UDID> --dropped`で止めているサービスを確かめる。要る分類（`simslim profiles`）があれば、`simslim on <UDID> --except photos,<分類>`で残して入れ直し（端末は再起動する）、確かめ終えたら`--except photos`で入れ直す。設定は端末を再起動しても消えないが、`xcrun simctl clone`で作った端末には引き継がれない
- 画面は`Tools/sim.sh dump '<使う端末>'`で文字として読む。要素の中心の座標（タップと同じポイント）や、タイムラインの`contentOffset.y`などの状態も出る。初回は、アプリに要素を作らせる設定を端末に入れ、起動し直しを求める。この設定でアプリが少し重くなるので、hitchを測るときは`Tools/sim.sh ctl '<使う端末>' spawn defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled`で外す
- 見た目を確かめるときは、シミュレーターのツールの`screenshot`ではなく`Tools/sim.sh shot '<使う端末>'`で撮る。1枚のトークンが約1/5になる。`--full`で残した原寸のPNGは、ユーザーに送るためのもので、自分では読まない
- URLを送ったあとや操作のあとに`sleep`しない。続けて行うコマンドは1つのBashの呼び出しにまとめる（例: `Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://reset' && Tools/sim.sh dump '<使う端末>'`）
- 確かめの準備で設定を変えるときは、設定の画面をタップでたどらずに、`scia-debug://settings/list`と`scia-debug://settings/set`で入れる（docs/debug-urls.mdの「設定」）。設定の画面そのものを確かめるときだけタップで変え、スイッチ（`UISwitch`、SwiftUIの`Toggle`）は、シミュレーターのツールの`tap`に`duration`を0.15秒ほど付けて押す。`duration`を付けない`tap`では、どちらも切り替わらない
- タップやスワイプのあとは、dumpで結果を確かめてから次へ進む。思った画面でなければ、同じ座標を打ち直さず、dumpから座標を取り直す
- 画像の読み込みのように、動きのないまま中身が後から入る表示は、止まっていても終わっていない。目的の要素が出るまでdumpし直す。ダミー投稿の画像は、流してから1〜2秒で入る
- 写真のピッカーは別のプロセスが描くので、`sim.sh`はその表示を待たない。アプリを起動して最初に開いたときだけ、表示まで数秒かかる。撮った画像にピッカーが写っていなければ、dumpで`mediaPicker: shown`を確かめて、数秒後に撮り直す
