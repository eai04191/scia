# ログに出してよい値

info以上のログは違和感レポートに入り、レポートはアプリのDocumentsに保存されて、ファイルアプリから取り出せる。`privacy: .public`で出した値はそのまま読める。端末のシステムのログ（sysdiagnose）にも残る。そのため、レポートを人に渡しても、誰が何を読み、何を書いたかが分からないようにする。

`OSLogStore`で読むと、`.private`の値は`<private>`に、`.private(mask: .hash)`の値は`<mask.hash: '…'>`に伏せられる。同じ値は同じハッシュになるので、値を出さずに、同じものかどうかは追える。privacyを書かない文字列は、Macで確かめたところ伏せられずにそのまま出たため、文字列には必ずprivacyを書く。

## 出してよいもの（`.public`）

- アプリのコードが決めた値: 種類の名前、enumの`rawValue`、固定の文字列、画面や部品の名前
- 数、真偽、大きさ、座標、時間
- HTTPのメソッドとステータス、`URLError`のコード、`SciaLog.describe`が作る失敗の説明（型の名前、`NSError`の領域とコード）
- IDを伏せたAPIのパス（`RequestLog`）、MIMEタイプ
- サーバーが振ったID（投稿、通知、アカウント、リスト、既読位置）。サーバーに問い合わせないと中身が分からず、状態ダンプのIDと突き合わせるのに要るため
- URLのホスト（`SciaLog.host(of:)`）。どのサーバーやCDNで失敗したかを絞るのに要るため
- 機種の識別子とOSの版

## 伏せるもの

次のものは`.public`で出さない。同じものかを追いたいときは`.private(mask: .hash)`、要らなければ出さない。

- ハンドル、表示名、ハッシュタグの名前、リストの名前
- 本文、入力した文字、代替テキスト、blurhash
- URL全体、URLのパスとクエリ、ファイルの名前とパス
- 応答の本文、サーバーが返した文言（`ErrorPresentation`の`message`と`text`を含む）
- `localizedDescription`と`String(describing: error)`。APIの失敗では応答の本文を、ファイルの失敗ではパスを、URLの失敗ではURLを含む。失敗は`SciaLog.describe`で書く

URLは`SciaLog.host(of:)`でホストだけを`.public`にし、どのURLかを追いたいときは、URL全体を`.private(mask: .hash)`で添える。

## 例外

- デバッグ版では、`RequestLog`が失敗した応答の本文を足す。リリース版では足さない
- `App/Sources/Debug`のデバッグ用のコードは、リリース版に入らないため、この決まりの対象にしない
- 状態ダンプも違和感レポートに入るため、同じ決まりで書く

## 守らせ方

`make lint`の`log_private_value`が、ログの1行の中で、伏せるものを`.private`か`.sensitive`以外で出す書き方を止める。止めるのは、`localizedDescription`、`absoluteString`、`String(describing: error)`、失敗をそのまま補間する書き方、`acct`や`username`のようなハンドルや本文の名前、URLを丸ごと補間する書き方。名前で見分けているため、別の名前に入れ替えた値は止められない。新しく伏せるものの名前を使い始めたら、この規則に足す。
