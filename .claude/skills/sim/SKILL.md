---
name: sim
description: シミュレーター（Scia 1〜Scia 4。名指しすればScia iPad 1、Scia Duoなども）を、触る間だけこのworktreeに借りる。空きがなければ空くまで待ち、端末が替わっていたら設定を戻してビルドを入れ直す。シミュレーターを触る直前に毎回、またはユーザーが/simで起動したときに使う。
argument-hint: "[番号か名前]"
---

# シミュレーターを借りる

端末は4台しかないので、スレッドが4つより多くても回るよう、シミュレーターを触る間だけ借りて、触り終えたらすぐ返す。コードを書いたりビルドしたりしている間は持たない。貸し借りは`Tools/sim.sh`がworktreeごとに記録する。並行するスレッドはworktreeを分けるので、借り手はworktreeで表す。

引数（`$ARGUMENTS`）には、使う端末の番号（1〜4）か名前（`Scia iPad 1`、`Scia Duo`など）が入ることがある。ユーザーが特定の端末を指定したときと、iPadや画面を開閉するiPhoneでの見え方を確かめるときだけ渡す。

## 1. 借りる

シミュレーターを触る直前（確かめ、録画、`ONLY`を付けた`make test`、`Tools/sim.sh shot`・`dump`の前）に、`Tools/sim.sh acquire`を走らせる。番号を指定されたら`Tools/sim.sh acquire 'Scia <番号>'`、名前なら`Tools/sim.sh acquire '<名前>'`にする。端末を省くと番号の端末から貸し、ほかの端末（`Scia iPad 1`、`Scia Duo`など）は名指ししたときだけ貸す。名指しで借りた端末は、端末を省いた`acquire`で番号の端末を借りても持ったままになり、別の端末を名指しすると返る。

`SIM`も`ONLY`も付けない`make test`、`make check`、`make check-test`では借りない。入口が別のMacか手元の枠を選び、手元の枠で走るときは入口が借りて返すため（docs/test-dispatch.md）。

- 空きがなければ、空くまで待つ。ユーザーには聞かない。540秒待っても空かなければ終了コード75で終わるので、もう一度走らせて待ち続ける。Bashのtimeoutは600000にする
- 返した端末でも、ほかのスレッドが残したバックグラウンドの処理（`make test`、録画など）が走っていれば貸さない
- 出力の最後の行が、借りた端末と状態になる（例: `Scia 2 ready`）。以後、シミュレーターのツールの`device`と`Tools/sim.sh`には、この端末を渡す。`ONLY`を付けた`make test`と`make sim-keyboard`は、借りている端末を自分で選ぶので`SIM`を渡さない。`shot`、`dump`、`reset`、`ONLY`か`SIM`を付けた`make test`は、借りていない端末には使えない

## 2. 状態で分ける

- `ready`なら、前にこのworktreeが設定を戻してビルドを入れ、そのあとほかのworktreeに貸していない。そのまま使う。ただしユーザーが手で触ったことはありうるので、確かめに要る設定は前提にせず、確かめる直前に入れる
- `claimed`なら、ほかのworktreeが使ったあとか、前に入れ終えないまま返した端末なので、次をすべて行う
  - `Tools/sim.sh reset '<端末>'`で、アプリを終了し、アプリの設定（設定、チューニング、デバッグ用の値）を既定に戻す。前に使ったスレッドが確かめのために変えた値を持ち込まないため。ログイン情報とアカウントの並びは残る
  - このworktreeのビルドを入れる。`make test`はテストのたびに入れるので、`make test`だけなら要らない
  - 入れ終えたら`Tools/sim.sh ready '<端末>'`で記録する。途中で失敗したら記録しない。次に借りたとき`claimed`のまま読めて、やり直せるようにするため

## 3. 返す

触り終えたら、`Tools/sim.sh release`で返す。ターンを返す前にも必ず返す。次にまた触るときは、1から借り直す。同じ端末が空いていれば、それを優先して貸すので、入れ直しを省ける。

- 30分たつと貸し出しは切れて、ほかのworktreeに貸される。続けて長く使うときは、30分たつ前に`Tools/sim.sh acquire`を走らせ直して延ばす
- 返したあともバックグラウンドで端末を使い続ける処理（`make test`、録画）は、その処理が終わるまでほかのworktreeに貸されない。処理の結果を待つ間は、返しておいてよい

今の貸し借りは`Tools/sim.sh status`で見られる。

## 4. 端末を触るときの決まり

- iPadと画面を開閉するiPhoneでの見え方は、`Scia iPad 1`、`Scia iPad 2`（iPad mini）、`Scia Duo`（iPhone Duo）で確かめる。`Tools/sim.sh acquire 'Scia iPad 1'`のように名指ししたときだけ借りられ、端末を省いた`acquire`と`make test`には使われない。名指しで借りた端末は、端末を省いた`acquire`で番号の端末を借りても持ったままになり、別の端末を名指しすると返る。ログインしていない端末では`scia-debug://dummy-session`で入る
- iPadでは、アプリが画面の一部のウインドウで開く。`dump`の座標は画面の座標（タップと同じ）で、ウインドウの位置と大きさは`ウインドウ`の行の`枠`に出る
- `Scia Duo`は画面が2つあり、`simctl io`の`screenshot`と`recordVideo`は`--display`がないと失敗する。`Tools/sim.sh shot`は主の画面（`primary`）を撮り、ほかの画面は`--display`で渡す。録画は`io recordVideo --display=primary`で撮る
- 端末に命令を送る`xcrun simctl`（`openurl`、`spawn`、`launch`、`install`、`io`など）は、直接呼ばずに`Tools/sim.sh ctl '<使う端末>' <操作> <引数...>`で送る。貸し借りを確かめてから`xcrun simctl <操作> '<使う端末>' <引数...>`を走らせる。直接の呼び出しと、借りていない端末を指したシミュレーターのツールは、hook（`.claude/settings.json`、`Tools/sim-lease-guard.py`）が実行の前に止める。simctlは名前を渡せばどの端末にも届き、借りた端末を確かめずに別の名前を書くと、ほかのスレッドの端末を触ってしまうため。端末は名前で書く（UDID、`booted`、`all`は受け付けない）。`list`と`get_app_container`のような、端末を変えない操作は直接呼んでよい。`Tools/sim.sh acquire`の出力の最後の行で借りた端末を読んでから、次のコマンドで送る
- 4台は同じアカウントでログインしているため、サーバー上の状態は共有される。読んだ位置は`api/v1/markers`でサーバーに保存され、起動時に読み込まれるので、別のスレッドがスクロールすると次の起動位置が変わる。投稿やブーストも、ストリーミングで他の端末に流れ込む。起動時の位置や新着の挙動を確かめるときは、他のスレッドの操作で結果が乱れていないか疑う
- 端末のリセット（`xcrun simctl erase`）や別の端末での起動をすると、ユーザーにログインし直してもらう必要がある
- 貸し借りする端末は、メモリを減らすため、[simslim](https://github.com/MobAI-App/simslim)で写真以外の使わないサービスを止めている（`simslim on <UDID> --except photos`）。プッシュ通知、ユニバーサルリンク、iCloud、Spotlight、言語のデータの読み込みなどは、エラーを出さずに動かないことがある。こうした機能が動かないときは、Sciaの不具合と決める前に`simslim status <UDID> --dropped`で止めているサービスを確かめる。要る分類（`simslim profiles`）があれば、`simslim on <UDID> --except photos,<分類>`で残して入れ直し（端末は再起動する）、確かめ終えたら`--except photos`で入れ直す。設定は端末を再起動しても消えないが、`xcrun simctl clone`で作った端末には引き継がれない
- 画面は`Tools/sim.sh dump '<使う端末>'`で文字として読む。アプリの中でアニメーションとスクロールの慣性が止まるのを待ってから（多くは1秒ほど）、要素の名前と中心の座標（タップと同じポイント）、タイムラインの`contentOffset.y`などの状態を出す。初回は、アプリに要素を作らせる設定を端末に入れ、起動し直しを求める。この設定でアプリが少し重くなるので、hitchを測るときは`Tools/sim.sh ctl '<使う端末>' spawn defaults delete com.apple.Accessibility ApplicationAccessibilityEnabled`で外す
- 見た目を確かめるときは、シミュレーターのツールの`screenshot`ではなく`Tools/sim.sh shot '<使う端末>'`で撮る。画面が止まるのを待ってから、端末のポイント幅に縮小したJPEGを出すので、画像の座標がそのままタップの座標になり、1枚のトークンも約1/5になる。`--crop x,y,幅,高さ`で一部を切り出し、`--full <ファイル>`でユーザーに送る原寸のPNGも残す。原寸は自分では読まない
- URLを送ったあとや操作のあとに`sleep`しない。`dump`と`shot`が画面が止まるまで待つので、続けて行うコマンドは1つのBashの呼び出しにまとめる（例: `Tools/sim.sh ctl '<使う端末>' openurl 'scia-debug://reset' && Tools/sim.sh dump '<使う端末>'`）
- タップやスワイプのあとは、dumpで結果を確かめてから次へ進む。思った画面でなければ、同じ座標を打ち直さず、dumpから座標を取り直す
- 画像の読み込みのように、動きのないまま中身が後から入る表示は、止まっていても終わっていない。目的の要素が出るまでdumpし直す。ダミー投稿の画像は、流してから1〜2秒で入る
- 写真のピッカーは別のプロセスが描くので、`sim.sh`はその表示を待たない。アプリを起動して最初に開いたときだけ、表示まで数秒かかる。撮った画像にピッカーが写っていなければ、dumpで`mediaPicker: shown`を確かめて、数秒後に撮り直す
