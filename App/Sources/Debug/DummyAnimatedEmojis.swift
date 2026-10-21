#if DEBUG
import Foundation
import SciaCore

/// 動くカスタム絵文字の多い一覧を、実機でも手軽に出すためのダミーの投稿。スクロールの手触りや、描画とメモリの負荷を、動かす・止めるで比べるのに使う。
/// 絵文字は、実際のサーバーにある動く絵文字（misskey.ioのGIF 30種類とWebP 10種類）のURLを使う。
/// 端末で描いた画像では、コマの数や大きさが実物と違い、負荷を比べる意味が薄れるため。読み込みには通信が要る。
enum DummyAnimatedEmojis {
    private static let urls: [String] = [
        "https://media.misskeyusercontent.jp/emoji/misskeystackoverflow.gif",
        "https://media.misskeyusercontent.jp/emoji/petthex_syuilo.gif",
        "https://media.misskeyusercontent.jp/emoji/petthex_syuilo_9597.gif",
        "https://media.misskeyusercontent.jp/misskey/eb3648f2-fb4f-47b1-9d63-e5de673dba94.gif",
        "https://media.misskeyusercontent.jp/emoji/ai_bonk.gif",
        "https://media.misskeyusercontent.jp/misskey/7831a6c2-c2ca-49e1-813f-c68db3b415fc.gif",
        "https://media.misskeyusercontent.jp/misskey/f6294900-f678-43cc-bc36-3ee5deeca4c2.gif",
        "https://media.misskeyusercontent.jp/misskey/f78c11ab-9b26-45f2-944d-af2900f7292c.gif",
        "https://media.misskeyusercontent.jp/misskey/7088cc38-1c89-4667-86d2-91346ea5aa38.gif",
        "https://media.misskeyusercontent.jp/io/d2d4c6e0-1c76-4a32-bc30-7836e02aac3c.gif",
        "https://media.misskeyusercontent.jp/io/b25dfe62-f250-4e23-92de-6869a249525e.gif",
        "https://media.misskeyusercontent.jp/misskey/16bd73b2-5a15-44c5-84fb-90cba740ed33.gif",
        "https://media.misskeyusercontent.jp/io/38b4f2a6-1caa-451f-992b-29cee9768e15.gif",
        "https://media.misskeyusercontent.jp/io/45a238ca-6319-4781-8bbe-b6b4c6fcca73.gif",
        "https://media.misskeyusercontent.jp/io/19367aa6-e738-48bd-b998-39884e4ed32b.gif",
        "https://media.misskeyusercontent.jp/io/3c73c243-de1b-46f4-a2cc-aee75d913761.gif",
        "https://media.misskeyusercontent.jp/io/a93bbf8d-e5a0-43a0-8df7-3490bcedc82d.gif",
        "https://media.misskeyusercontent.jp/io/868020ad-25b3-4594-ad0b-73896fdd8035.gif",
        "https://media.misskeyusercontent.jp/io/a6beab09-ddb3-4502-80ae-1d579db97e98.gif",
        "https://media.misskeyusercontent.jp/io/db39e3af-06bd-4c8f-9f97-6c0209f30717.gif",
        "https://media.misskeyusercontent.jp/misskey/64acf4ac-c8aa-4030-b0be-ad3bcd7adce3.gif",
        "https://media.misskeyusercontent.jp/misskey/dfc0d57f-48c3-4306-b360-b1650aaa1383.gif",
        "https://media.misskeyusercontent.jp/io/c2f32e91-329d-4d3c-9697-20fd21993845.gif",
        "https://media.misskeyusercontent.jp/misskey/ba022783-f9ee-4a5f-ba09-0c5e5c5ff8b0.gif",
        "https://media.misskeyusercontent.jp/io/073e1637-0019-4476-99c2-f344a74065d8.gif",
        "https://media.misskeyusercontent.jp/io/d35c4786-3ddc-4a46-b7f9-21067ecdce60.gif",
        "https://media.misskeyusercontent.jp/io/46c16522-c8e3-41a7-aaa4-dd65d93335e9.gif",
        "https://media.misskeyusercontent.jp/io/2365a12c-d1af-4518-943e-91c5459bb368.gif",
        "https://media.misskeyusercontent.jp/io/a90f78eb-d709-4f85-999d-fc98bf2f47f2.gif",
        "https://media.misskeyusercontent.jp/misskey/4699f64f-cc3b-4673-b8d7-470de4e93851.gif",
        "https://media.misskeyusercontent.jp/io/202e479e-20f9-4669-91c2-8e534723792b.webp",
        "https://media.misskeyusercontent.jp/io/df3b5aa4-7efd-4a0a-8ded-782bd710aa43.webp",
        "https://media.misskeyusercontent.jp/io/0e09c09c-8c68-4f36-9fcc-f00da8ecf71e.webp",
        "https://media.misskeyusercontent.jp/io/d6dada99-c295-4256-afae-62ad11b2ff70.webp",
        "https://media.misskeyusercontent.jp/io/c0c24edc-d23d-4b50-912a-b9261ee141a2.webp",
        "https://media.misskeyusercontent.jp/io/34e98b0c-b1ea-4425-bc03-567fa4eab2bf.webp",
        "https://media.misskeyusercontent.jp/io/ad0321dd-fc5b-49ec-9ec4-fc9f6db378f7.webp",
        "https://media.misskeyusercontent.jp/io/6631e0a8-4212-4bd5-81a6-d842a0f210ee.webp",
        "https://media.misskeyusercontent.jp/io/576e54e1-0955-4257-93c4-b4d1314171c4.webp",
        "https://media.misskeyusercontent.jp/io/4619ab81-3db1-4e3a-964f-bbace4a4004c.webp",
    ]

    /// 投稿の数。
    static let postCount = 40
    /// 1件の投稿に入れる絵文字の数。
    static let emojisPerPost = 8

    /// 投稿`number`（0から）の本文と絵文字。どの投稿にも、40種類から8種類を、投稿ごとにずらして選ぶ。
    static func content(number: Int) -> (html: String, emojis: [CustomEmoji]) {
        let all = urls.enumerated().compactMap { index, string in
            URL(string: string).map { CustomEmoji(shortcode: "anim\(index)", url: $0, staticUrl: $0) }
        }
        guard !all.isEmpty else { return ("<p>絵文字のURLを読めませんでした</p>", []) }
        // 7は40と互いに素なので、投稿ごとに選ぶ絵文字の組み合わせがずれ、8つが重ならない。
        let emojis = (0..<emojisPerPost).map { all[(number * emojisPerPost + $0 * 7) % all.count] }
        let text = emojis.map { "動く :\($0.shortcode):" }.joined(separator: " ")
        return ("<p>\(text) 投稿\(number)</p>", emojis)
    }
}
#endif
