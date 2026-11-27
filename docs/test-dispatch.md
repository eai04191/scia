# テストの振り分け

`make check`、`make test`、`make check-test`は、Tailscaleでつないだ別のMacと手元のMacの、空いている枠で走らせる。手元のMacの負荷を下げるため。`make`と`Tools/merge-queue.sh`の両方が、入口の`Tools/test-dispatch.sh`を通る。別のMacで動くのは`Tools/remote-test-worker.sh`。

`make build`と、シミュレーターを触って確かめる作業は手元で行う。

通った回は、そのビルドのアプリを`DerivedData/checked/Scia.app`に、確かめたtreeを`DerivedData/checked/tree`に置く（`Tools/keep-checked-app.sh`）。別のMacで通った回は、別のMacが`~/scia/apps/<依頼のID>`に残したものを入口が受け取る。手元のビルドの成果物（`Build/Products`）とは分けて置き、別のMacでビルドした中身を手元の差分ビルドに混ぜない。入口は手元の`Config/Local.xcconfig`の`DEVELOPMENT_TEAM`を別のMacへ渡し、別のMacは作業コピーの`Config/Local.xcconfig`に書いてビルドする。`application-identifier`が手元のビルドと違うと、受け取ったアプリが手元のキーチェーンのログインを読めないため。

## 流れ

1. 順番待ちのチケットを取る。`Tools/merge-queue.sh`は、待たせるとmainへ入れる処理の全体が止まるので、列の先頭に並ぶ
2. チケットが先頭になるまで待つ
3. 別のMacに依頼する。受け付けられたらチケットを外し、次の依頼に番を譲る
4. 断られたか届かなければ、手元の枠を取る。取れたらチケットを外して手元で走らせる
5. どちらも空いていなければ、5秒おいて3から試し直す

枠は、別のMacが`SCIA_REMOTE_SIMS`の端末の数、手元が2（`Tools/test-dispatch.sh`の`LOCAL_SLOTS`）。

落ちたテストは、もう一方の枠で走らせ直さない。

## 手元の枠だけを使うとき

- `SCIA_REMOTE_TEST=local`を付けたとき
- `scia-remote-test.conf`がないとき
- 別のMacが受け付けないとき（貸し出しを止めている、電源につながっていない）
- 別のMacに届かないとき

別のMacで走らせている途中で接続が切れたり、貸し出しを止めて中断されたりしたら、手元の枠で最初から走らせ直す。

## 枠を取らないとき

`SIM`か`ONLY`を指定したときは、その端末で確かめるための実行なので、枠を取らずに手元で走らせる。

## 別のMacでの実行

作業ツリーのtreeを送り、受け取った側で同じtreeになることを確かめてから走らせる。通ったら手元の`.git/scia-check/`にそのtreeを記録するので、mainのhookは手元で通したときと同じように扱う。

別のMacは、`SCIA_REMOTE_SIMS`の端末の数だけ、作業コピー（`~/scia/tree-<番号>`）と端末の組で同時に走らせる。

落ちた回のxcresultと出力の全文は、別のMacの`~/scia/results/<依頼のID>`に移し、入口が手元の`DerivedData/test-logs`へ受け取って別のMacの分を消す。xcresultは`failed-<時刻>`、出力の全文は`remote-output-<依頼のID>`に入る。受け取れなければ別のMacに7日残る。

`make check`で並べて走らせるlintとmacOSのテストは、対象ごとに`DerivedData/check-logs/<対象>.log`へ書く。落ちた対象は、`==== 落ちた: <対象>`から`==== ここまで: <対象>`の間に、ログ全体から選んだ失敗の行とログの末尾を入れた区間を`<対象>.failed`に書き、並べた対象が全部終わってから出す（`Tools/check-logged.sh`）。別のMacも、この間の行をそのまま返す。

## 手元の端末

手元で走らせる`make test`の端末は、そのworktreeが借りていれば、貸し出しの期限を延ばしてそれを使い、終わっても返さない。借りていなければ入口が借りて、ほかのworktreeが使ったあとなら設定を既定に戻し、終わったら返す。

## 貸し出しを止める

別のMacで`touch /Users/Shared/scia-runner-paused`を走らせると、新しい依頼を受け付けず、走っているテストを中断してシミュレーターも止める。再開は`rm /Users/Shared/scia-runner-paused`。

## 設定

worktreeどうしで共有する`.git`の共通ディレクトリに`scia-remote-test.conf`を置く。

```bash
SCIA_REMOTE_HOST=runner@<別のMacのTailscale IP>
SCIA_REMOTE_KEY=$HOME/.ssh/<鍵>
SCIA_REMOTE_SIMS=('Scia Remote 1' 'Scia Remote 2')
```

## 別のMacの準備

- XcodeとiOSランタイムの版を手元と揃え、`brew install xcodegen swiftlint mobai-app/tap/simslim`で入れる
- テスト専用の通常ユーザー`runner`を作り、手元の公開鍵を`authorized_keys`に登録する
- `/etc/ssh/sshd_config.d/000-scia.conf`を次の内容で置いてから、「リモートログイン」をオンにして`runner`だけを許可する

  ```text
  AllowUsers runner@<手元のMacのTailscale IP>
  AuthenticationMethods publickey
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  ```

- `runner`で、`security create-keychain -p '' login.keychain`、`security default-keychain -s login.keychain`、`security list-keychains -d user -s login.keychain`、`security set-keychain-settings login.keychain`を走らせる。GUIセッションがないとログインキーチェーンができず、SciaCoreのKeychainのテストが落ちる
- `runner`で、`xcrun simctl create 'Scia Remote <番号>' com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-2`で、`SCIA_REMOTE_SIMS`の端末を作る
- `runner`で、作った端末ごとに`simslim on <UDID> --except photos`を走らせる。手元の`Scia 1`〜`4`と同じく、メモリを減らすため

## 落ちたテストの記録

- `make test`の記録: 全部を走らせると、`DerivedData/test-logs/watch-<時刻>`に実行中の負荷（`load.log`）と、30秒たっても終わらないSciaCoreのテストのスタック（`<テストの名前>-<ハッシュ>.sample.txt`。名前の英数字のほかは`_`になるので、どのテストかは末尾の`test:`の行で見る）が残る。落ちた回の`.xcresult`と、その回の`watch-<時刻>`のコピーは、`DerivedData/test-logs/failed-<時刻>`に残る
- テストが落ちたら、`DerivedData/test-logs/failed-<時刻>`のxcresultを`xcrun xcresulttool get test-results tests --path <xcresult>`で読む。別のMacで走った分も手元のここに届く。式の実際の値は`make test`の出力に残らず、ここにある。落ちたテストの前後のアプリのログ（`SciaLog`）は、`xcrun xcresulttool export diagnostics --path <xcresult> --output-path <フォルダー>`で取り出した`StandardOutputAndStandardError.txt`にある（`get log --type console`では出ない）

### 失敗時の共通診断

`.scratch`と`.stallLimit`のテストでは、最初の失敗時に`failure-diagnostics.txt`をSwift Testingの添付ファイルとして残す。OS、CPU数、失敗を記録したスレッドのスタックと、`Gate`・`TestClock`・`waitUntil`の履歴が入る。履歴は直近128件を残し、それ以前の件数を表示する。各待機オブジェクトの最後の状態は、履歴から外れても残る。並列のテストケースは別々に記録する。

`.scratch`では、その時点で残っている登録済みのファイルと設定のplistも、削除する前に添付する。`scratch-files.txt`が添付名と元のパスの対応表で、読み取れなかったファイルの理由もここに残る。テストがすでに削除したファイルは復元しない。シンボリックリンクは添付しない。

`make test-core`と`make test-release`の添付は`DerivedData/test-logs/failed-attachments-<実行ごとの識別子>/`、Xcodeで走るテストの添付はxcresultに入る。`swift test`を直接使うときは、先に保存先を作って`--attachments-path <保存先>`を渡す。指定しないとSwift Testingが添付を破棄する。Release testのCIでは、失敗時にログと添付を`release-test-diagnostics` artifactへ保存する。

`.scratch`も`.stallLimit`もないテストには、Swift Testingの公開APIで一括の失敗ハンドラーを設定できない。`waitUntil`のタイムアウトでは設定によらず失敗を記録したスレッドのスタックを出すが、その場合は待機オブジェクトの履歴を収集しない。スタックは停止中の全asyncタスクの履歴ではなく、失敗を報告した時点のもの。プロセス全体が止まった場合は、既存のwatchスクリプトが採るスタックを使う。
