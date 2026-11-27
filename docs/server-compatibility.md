<!--
この文書は、ほかの文書と違い、人も読む。である調で書く。Mastodon互換の実装の開発者に見せて、直すきっかけにするため。
短く平易に書く。1項目は、何が違うか、どこに原因があるか、Sciaが何をしているかの3つだけにし、長い箇条書きにしない。
載せるのは、Sciaが話すサーバーのMastodon API（要求と応答）が、Mastodonと違うためにSciaが手当てしているものだけ。連合で届く投稿の中身（ほかのサーバーが配った本文のHTMLなど）の違いは、互換APIの違いではないので載せない。Mastodonが今も受け付ける古いAPI（v1）しかないことも、違いとして載せない。Mastodonにない拡張API（絵文字のリアクション、Fedibirdの引用など）の実装ごとの違いは載せない。
リンクはcommitに固定したパーマリンクにする。確かめ直したら、確認日と版を更新する。直ったリリースが出て、Sciaの手当てを外したら、項目を消す。
-->

# Mastodon互換の実装との違い

SciaはMastodonのクライアントで、[Mastodonのドキュメント](https://docs.joinmastodon.org/)のとおりにAPIを使う。ここに並べるのはMastodon互換のAPIを持つ実装が、そのAPIでMastodonと違う振る舞いをするため、Sciaが手当てしている違いである。

| 違い | 実装 | 確認日 |
|---|---|---|
| [ストリーミングで`Authorization`ヘッダーを読まない](#streaming-auth) | Pleroma、Akkoma | 2026-11-24 |
| [`GET /api/v1/instance`に`configuration`がない](#instance-v1-configuration) | Akkoma | 2026-11-24 |
| [受け付ける形式が`application/octet-stream`だけ](#supported-mime-types) | Pleroma | 2026-11-24 |
| [form形式の`media_ids[]`を捨てる](#media-ids-form) | Sharkey、Catodon | 2026-11-24 |
| [ストリーミングの接続先を返さない](#streaming-url) | Hollo | 2026-11-24 |
| [編集の`media_attributes`を読まない](#media-attributes) | Pleroma、Akkoma、Sharkey、Catodon | 2026-11-24 |

確認日はリンク先のソースを読んだ日である。Dockerで立てたサーバーで動きも確かめたものは、その旨を書く。

<a id="streaming-auth"></a>

## ストリーミングで`Authorization`ヘッダーを読まない

MastodonはWebSocketのトークンを`Authorization`ヘッダーで受け取る。PleromaとAkkomaはこのヘッダーを読まず、クエリの`access_token`か`Sec-WebSocket-Protocol`でだけ受け取る。ヘッダーだけで渡すと匿名の接続になり、`user`の購読を断られる。

- Pleroma 2.11.1（developも同じ）: [endpoint.ex#L17](https://git.pleroma.social/pleroma/pleroma/src/commit/762058f2c5c0fa28aec13132bccd1ce454b9ff7a/lib/pleroma/web/endpoint.ex#L12-L21)、[websocket_handler.ex#L249-L264](https://git.pleroma.social/pleroma/pleroma/src/commit/762058f2c5c0fa28aec13132bccd1ce454b9ff7a/lib/pleroma/web/mastodon_api/websocket_handler.ex#L249-L264)
- Akkoma 3.20.1（developも同じ）: [websocket_handler.ex#L24-L29](https://akkoma.dev/AkkomaGang/akkoma/src/commit/98dd958886a8b0ef65d5bd827aba3789f1dc5116/lib/pleroma/web/mastodon_api/websocket_handler.ex#L24-L29)

Sciaはトークンを`Sec-WebSocket-Protocol`でも渡す。

<a id="instance-v1-configuration"></a>

## `GET /api/v1/instance`に`configuration`がない

Mastodonはv1の`instance`にも、文字数などの上限を`configuration`で返す。Akkomaはv2の`instance`を持たず、v1にも`configuration`を返さず、上限を一番上の独自の項目（`max_toot_chars`、`description_limit`、`upload_limit`、`poll_limits`）で返す。そのため、Mastodonの形では上限を読めない。

- Akkoma 3.20.1（developも同じ）: [instance_view.ex#L35-L43](https://akkoma.dev/AkkomaGang/akkoma/src/commit/98dd958886a8b0ef65d5bd827aba3789f1dc5116/lib/pleroma/web/mastodon_api/views/instance_view.ex#L13-L57)

Sciaは`configuration`がなければこれらの項目から上限を読む。

<a id="supported-mime-types"></a>

## 受け付ける形式が`application/octet-stream`だけ

Mastodonは`configuration.media_attachments.supported_mime_types`にアップロードできる形式を並べる。Pleromaはここに`["application/octet-stream"]`だけを決め打ちで返す。実際はどの形式も受け付けるが、一覧のとおりに読むと、JPEGもPNGも受け付けないことになる。

- Pleroma 2.11.1（developも同じ）: [instance_view.ex#L299](https://git.pleroma.social/pleroma/pleroma/src/commit/762058f2c5c0fa28aec13132bccd1ce454b9ff7a/lib/pleroma/web/mastodon_api/views/instance_view.ex#L296-L300)

Sciaは一覧に`application/octet-stream`があれば、形式を絞らないものとして扱う。

<a id="media-ids-form"></a>

## form形式の`media_ids[]`を捨てる

Mastodonは本文をform形式でもJSONでも同じように受け付け、form形式では配列を`media_ids[]=…`で送ると[ドキュメント](https://docs.joinmastodon.org/client/intro/#parameters)に書いている。SharkeyとCatodonは、`media_ids[]`を`media_ids`に読み替えようとするが、`querystring`で文字列にしてもう一度解析するだけなので名前が変わらず、添付のない投稿をエラーなしで作る（Dockerで確かめた）。`poll[options][]`も同じ処理を通る。

- Sharkey 2025.4.7（developも同じ）: [status.ts#L19-L22](https://activitypub.software/TransFem-org/Sharkey/-/blob/a5d61c9394bb7a9c61d5ff19d17966b2d55f7b1f/packages/backend/src/server/api/mastodon/endpoints/status.ts#L19-L22)、[#L159-L168](https://activitypub.software/TransFem-org/Sharkey/-/blob/a5d61c9394bb7a9c61d5ff19d17966b2d55f7b1f/packages/backend/src/server/api/mastodon/endpoints/status.ts#L159-L168)
- Catodon 26.11.1: [status.ts#L29-L32](https://codefloe.com/catodon/catodon/src/commit/c7445fc10d94da08bb48f945123913cbfb45bcc5/packages/backend/src/server/api/mastodon/endpoints/status.ts#L29-L32)。developでは[ea9b0e2](https://codefloe.com/catodon/catodon/commit/ea9b0e25959e65a6d892cc65d191ac8529a88bcb)で直っている（投票は未対応）

Sciaは投稿、予約、編集をJSONで送る。

<a id="streaming-url"></a>

## ストリーミングの接続先を返さない

Holloはv2の`configuration.urls.streaming`もv1の`urls.streaming_api`も返さない。ソースにTODOがあり、ストリーミング自体がまだない。

- Hollo 0.9.26（mainも同じ）: [v2/instance.ts#L87-L88](https://github.com/fedify-dev/hollo/blob/b4bd07e0b87994eee2a84f49aa9d96a72adb313f/src/api/v2/instance.ts#L87-L88)、[v1/instance.ts#L51](https://github.com/fedify-dev/hollo/blob/b4bd07e0b87994eee2a84f49aa9d96a72adb313f/src/api/v1/instance.ts#L51)

Sciaは、接続先がなくても上限は読み、ストリーミングの代わりにポーリングで新着を読む。

<a id="media-attributes"></a>

## 編集の`media_attributes`を読まない

Mastodonでは投稿に付いた添付の代替テキストを、編集の`media_attributes`で変える。Pleroma、Akkoma、Sharkey、Catodonはこれを読み捨てて200を返すので、代替テキストだけが変わらない（Dockerで確かめた）。

これらの実装では`PUT /api/v1/media/:id`で変えられるが、反映のされ方が違う。SharkeyとCatodonではその場で投稿に出る。PleromaとAkkomaでは、`media_ids`付きで編集し直すまで出ない。

- Pleroma 2.11.1: [status_operation.ex#L670-L722](https://git.pleroma.social/pleroma/pleroma/src/commit/762058f2c5c0fa28aec13132bccd1ce454b9ff7a/lib/pleroma/web/api_spec/operations/status_operation.ex#L670-L722)
- Akkoma 3.20.1: [status_operation.ex#L663-L715](https://akkoma.dev/AkkomaGang/akkoma/src/commit/98dd958886a8b0ef65d5bd827aba3789f1dc5116/lib/pleroma/web/api_spec/operations/status_operation.ex#L663-L715)
- Sharkey 2025.4.7: [status.ts#L216-L230](https://activitypub.software/TransFem-org/Sharkey/-/blob/a5d61c9394bb7a9c61d5ff19d17966b2d55f7b1f/packages/backend/src/server/api/mastodon/endpoints/status.ts#L216-L230)、[misskey.ts#L1189-L1250](https://activitypub.software/TransFem-org/Sharkey/-/blob/a5d61c9394bb7a9c61d5ff19d17966b2d55f7b1f/packages/megalodon/src/misskey.ts#L1189-L1250)
- Catodon 26.11.1（developも同じ）: [status.ts#L553-L570](https://codefloe.com/catodon/catodon/src/commit/c7445fc10d94da08bb48f945123913cbfb45bcc5/packages/backend/src/server/api/mastodon/endpoints/status.ts#L553-L570)、[MastodonClientShim.ts#L1338-L1412](https://codefloe.com/catodon/catodon/src/commit/c7445fc10d94da08bb48f945123913cbfb45bcc5/packages/backend/src/server/api/mastodon/shim/MastodonClientShim.ts#L1338-L1412)

SciaはまずMastodonの形で編集を送る。返った投稿で代替テキストが変わっていなければ、`PUT /api/v1/media/:id`を送り、同じ編集をもう一度送る。PleromaとAkkomaは編集し直すまで投稿に出さず、SharkeyとCatodonは`PUT`ではほかのサーバーへ送らないためである。そのため、これらの実装では編集の履歴に版が1つ多く残る（Dockerで確かめた）。
