# テストの振り分け

`make check`、`make test`、`make check-test`は、Tailscaleでつないだ別のMacと手元のMacの、空いている枠で走らせる。手元のMacの負荷を下げるため。`make`と`Tools/merge-queue.sh`の両方が、入口の`Tools/test-dispatch.sh`を通る。別のMacで動くのは`Tools/remote-test-worker.sh`。

`make build`と、シミュレーターを触って確かめる作業は手元で行う。

## 流れ

1. 順番札を取る。`Tools/merge-queue.sh`は、待たせるとmainへ入れる処理の全体が止まるので、列の先頭に並ぶ
2. 札が先頭になるまで待つ
3. 別のMacに依頼する。受け付けられたら札を外し、次の依頼に番を譲る
4. 断られたか届かなければ、手元の枠を取る。取れたら札を外して手元で走らせる
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

作業ツリーのtreeを送り、受け取った側で同じtreeになることを確かめてから走らせる。通ったら手元の`.git/scia-check/`にそのtreeを覚えるので、mainのhookは手元で通したときと同じように扱う。

別のMacは、`SCIA_REMOTE_SIMS`の端末の数だけ、作業コピー（`~/scia/tree-<番号>`）と端末の組で同時に走らせる。

落ちた回のxcresultは、別のMacの`~/scia/results/<依頼のID>`に移し、入口が手元の`DerivedData/test-logs/failed-<時刻>`へ受け取って別のMacの分を消す。受け取れなければ別のMacに7日残る。

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
