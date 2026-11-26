# アプリのURL

`scia://`のURLで画面を開くときに、作者が決めたこと。開ける画面のリストは下の「開ける画面」にある。アプリの中から画面を開くとき（謝辞の「アカウント」、設定の「シートの高さ」など）も、同じ入り口を通す。

## 重ねた画面との関係

- タブを選ぶか、タブにプッシュして見せる行き先（タブ、プロフィール、スレッド、人のリスト、ハッシュタグ、検索、予約投稿、保留中の通知など）は、上に重ねた画面をすべて閉じてから開く。重ねたままでは見えないため。送られた行き先は使う人の新しい操作なので、書きかけのある画面（メモ、プロフィールの編集、通報など）も閉じ、書きかけは失う。アプリ内のSafariは、タブのすぐ上にあれば閉じずに伏せた高さへ下げて、後ろの画面に開く。伏せた高さのない画面（iPhoneの横向き）では閉じる
- 確認のアラートが出ていれば、何も閉じずに開くのをやめる。アラートは答えを待っている途中で、選ばずに閉じると、選んだときの後始末がされないため
- 並びにないか無効にしているタブへの行き先は、開けないので、何も閉じずにやめる。閉じても見せるものがなく、書きかけやページを失うだけになるため
- 設定、メモ、通報、お知らせのように手前に重ねる行き先は、下の画面を残して重ねる。ビューアのメニューの「カスタマイズ」から開いた設定を閉じると、ビューアに戻るため
- 重ねた画面のどれかを閉じている途中に届いたら、閉じ終えてから開く

## 開ける画面

画面を足したら、`AppDestination`に開く先を足し、ここにも書く。デバッグ版だけの画面と操作（`scia-debug://`）は[debug-urls.md](debug-urls.md)にある。

- タブ: `scia://tab/<home|local|federated|notifications|search|bookmarks|favourites|scheduled|followed-tags>`。足したタブは`tab/list?id=<リストのID>`、`tab/hashtag?name=<名前>`、`tab/profile?acct=<ハンドル>`、`tab/account-hashtag?acct=<ハンドル>&name=<名前>`。並びにない、または無効にしているタブでは何もしない
- 設定: `scia://settings`。設定のトップの画面から入る画面は`settings/<画面>`で、トップの画面の上に重ねて開く（戻るとトップの画面に戻る）。分類の中の画面は、分類の画面を挟んで重ねる。分類は`display`（表示）、`interaction`（操作）、`compose`（作成）、`about`（情報）。画面は`account`（アカウントの画面）、`account-management`（アカウントを管理）、`app-icon`（アプリのアイコン）、`appearance`（投稿の見た目）、`notification-appearance`（通知の見た目）、`media`（メディア。表示の中）、`profile`（プロフィール。表示の中）、`custom-emojis`（描き方を変えたカスタム絵文字。表示の中）、`user-displays`（表示を変更したユーザー。表示の中）、`link-loading`（リンク先の読み込み）、`auto-translation`（自動翻訳）、`tabs`（タブ）、`app-preset`（アプリのプリセットを選ぶ。プリセットも挟んで重ねる）、`account-preset`（開いているアカウントのプリセットを選ぶ。プリセットも挟んで重ねる）、`presets`（プリセット）、`preset-management`（プリセットを管理。プリセットも挟んで重ねる）、`preset-comparison`（プリセットを比較。プリセットと管理も挟んで重ねる）、`<status|quoted-status|notification|user|link|external-post|hashtag|media|reaction>-actions`（操作の各対象。タップと長押しとメニュー）、`<status|user|link|external-post|profile-text|custom-emoji|hashtag|media|reaction>-menu`（メニューの各項目。プロフィールの文章とカスタム絵文字のほかは、対象の画面も挟んで重ねる）、`status-action-bar`（投稿のアクションバーのボタンの並び。投稿の操作の画面も挟んで重ねる）、`status-leading-swipe`と`status-trailing-swipe`（投稿を右にスワイプと左にスワイプして出すボタンの並び。投稿の操作の画面も挟んで重ねる）、`compose-tools`（投稿欄のボタン）、`connection`（接続の状態。情報の中）、`connection-timelines`（受信中のタイムライン。接続の状態も挟んで重ねる）、`storage`（ストレージ）、`storage-viewed`と`storage-prefetched`（ストレージのメディアのキャッシュの表示済みと先読み）、`licenses`（ライセンス。情報の中）、`acknowledgments`（謝辞。情報の中）。「投稿の見た目」の分類の画面は`settings/appearance/<分類>`で、分類は`row`、`context`、`avatar`、`name`、`body`、`spoiler`、`media`、`linkCard`、`xPost`、`poll`、`reactions`、`actionBar`、`reactionGlow`。「通知の見た目」の分類の画面は`settings/notification-appearance/<分類>`で、分類は`group`、`header`、`symbol`、`account`、`quoted`、`context`
- プロフィール: `scia://profile/<user@domain>`（ホームのタブに開く）、`scia://my-profile`（選んでいるタブに自分のプロフィールを開く）、`scia://profile-edit`（自分のプロフィールの編集）、`scia://note?acct=<ハンドル>`（その人へのメモ）、`scia://report?acct=<ハンドル>`（その人の通報。送らなければサーバーに届かない）
- 人のリスト: `scia://accounts/<followers|following>`（自分の。`?id=<アカウントのID>`でその人の）、`scia://accounts/<favourited|reblogged>?id=<投稿のID>`（その投稿をお気に入り、ブーストした人）、`scia://accounts/emoji-reactioned?id=<投稿のID>&name=<パーセントエンコードした絵文字>`（その投稿にその絵文字でリアクションした人）、`scia://accounts/<muted|blocked>`（自分がミュートした人、ブロックした人。フィルターと同じく単独のシートで出す。決まりはdocs/moderation-lists.md）
- タイムライン: `scia://hashtag?name=<名前>`（ハッシュタグ）、`scia://account-hashtag?acct=<ハンドル>&name=<名前>`（その人のハッシュタグ）、`scia://scheduled`（予約投稿。タブを無効にしていれば選んでいるタブにプッシュする）
- 投稿: `scia://thread?id=<投稿のID>`（スレッド）、`scia://edit-history?id=<投稿のID>`（編集履歴）、`scia://quotes?id=<投稿のID>`（その投稿を引用した投稿のタイムライン）、`scia://api-response?id=<投稿のID>`（その投稿を再読み込みしたAPIの応答のJSON）
- 検索: `scia://search?q=<パーセントエンコードした語>`（検索のタブに語を入れて確定する。`q`がなければタブを開くだけ。検索を無効にしていれば選んでいるタブにプッシュする）
- 投稿欄: `scia://compose/<tools|language|schedule|emoji|media-picker>`（書き始めて、ボタンの並び、言語、予約の日時、絵文字のパレット、メディアのピッカーを開く。予約していなければ予約を始める）、`scia://compose/<attachment|alt-text|crop>?index=<n>`（n番目の添付のビューア、その代替テキストの入力、切り抜き。先に`scia-debug://compose?media=<枚数>`で添付を足す）
- アカウントの画面: `scia://account`（シートで開く。設定に重ねるのは`scia://settings/account`。決まりはdocs/account-screen.md）
- サーバーのお知らせ: `scia://announcements`（お知らせのシート）
- 保留中の通知: `scia://notification-requests`（通知のタブに保留中の通知を送ってきた人のリスト）、`scia://notification-request?id=<保留中の通知のID>`（その上にその人からの通知）、`scia://notification-policy`（通知のフィルタリングの設定）。IDは`api/v1/notifications/requests`で調べる。ダミーのセッションでは`dummy-request-1`〜`3`
- 投稿のデフォルト: `scia://posting-defaults`（新しく投稿するときの公開範囲、引用できる人、言語、閲覧注意の既定を変えるシート。変えるとサーバーの設定が変わる。決まりはdocs/account-screen.md）
- 外観: `scia://account-appearance`（アカウント設定の外観のうち、Sciaが従う値を見せるシート。変更はウェブで行う。決まりはdocs/account-screen.md）
- フィルター: `scia://filters`（自分のフィルターを並べたシート。決まりはdocs/filters.md）
- ブロックしたドメイン: `scia://domain-blocks`（自分がブロックしたドメインを並べたシート。決まりはdocs/moderation-lists.md）
- そのほか: `scia://crash-report?id=<投稿のID>`（隔離した投稿について開発者に送る内容の画面。決まりはdocs/crash-quarantine.md）、`scia://operation-status`（操作の状況）、`scia://in-app-browser-height`（重ねた画面を閉じ、ホームの上にアプリ内のSafariの高さを選ぶシートを出す。`?return=<設定の画面>`で、閉じたときにその設定の画面を開き直す）
- 自分用の表示: `scia://user-display?acct=<user@domain>`。対象のユーザーを読み、表示名・アイコン・アニメーション停止の編集シートを開く。
