public import Foundation

/// 投稿に出すリンクカード。見せ方は`docs/link-card.md`。
public enum LinkCard: Equatable, Sendable {
    /// サーバーが作ったカード。
    case card(PreviewCard)
    /// サーバーがまだカードを付けていないか、作らなかったリンク。通信せずに分かるリンク先だけを出す。
    case link(URL)

    /// カードを押したときに開く先。
    public var url: URL {
        switch self {
        case .card(let card): card.url
        case .link(let url): url
        }
    }

    /// `status`に出すカード。サーバーのカードがあればそれを、なければ、サーバーがカードを付けそうな投稿のリンクを返す。
    /// どちらでもなければnil。ブーストなら、ブーストされた投稿を渡す。
    public init?(status: Status) {
        if let card = status.card {
            self = .card(card)
        } else if let url = Self.cardCandidate(in: status) {
            self = .link(url)
        } else {
            return nil
        }
    }

    /// サーバーがカードを付けそうなリンク。Mastodonと同じく、添付ファイルか引用のある投稿には付けず、
    /// 本文のリンクのうち、メンションとハッシュタグを除いた、最初のhttpかhttpsのリンクに付ける。
    /// 除くリンクは、MastodonのFetchLinkCardServiceと同じく、`rel`に`tag`があるもの、`class`に`u-url`か`h-card`を含むもの、
    /// 投稿のメンションの相手のURLと同じものと、表示でハッシュタグとメンションに分けている、`class`に`hashtag`か`mention`があるもの。
    /// サーバーは整える前の本文を見るが、APIで返る他のサーバーの投稿の本文は、`rel`が`nofollow noopener`に書き換えられて`tag`が残らないため、
    /// `class`でも除く。本文のHTMLのリンクを直接見るのは、`u-url`や`h-card`のように、表示の分類にない印も見るため。
    ///
    /// Mastodonは、自分のサーバーへのリンクも除く。ここでは除かないため、自分のサーバーの投稿へのリンクには、
    /// サーバーがカードを付けないまま、リンク先だけのカードが出る。見せ方の決まりで、カードが付かなかったときも
    /// リンク先だけのカードを残すため、見た目は付かなかった投稿と変わらない。
    static func cardCandidate(in status: Status) -> URL? {
        guard status.mediaAttachments.isEmpty, status.quote == nil else { return nil }
        let mentionURLs = Set(status.mentions.compactMap(\.url))
        for token in HTMLTokenizer.tokenize(status.content) {
            guard case .open("a", let attributes) = token,
                  let href = attributes["href"], let url = URL(string: href),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host() != nil
            else { continue }
            let rels = (attributes["rel"] ?? "").split(separator: " ")
            let classString = attributes["class"] ?? ""
            let classes = classString.split(separator: " ")
            guard !rels.contains("tag"), !classes.contains("hashtag"), !classes.contains("mention"),
                  !classString.contains("u-url"), !classString.contains("h-card"), !mentionURLs.contains(url)
            else { continue }
            return url
        }
        return nil
    }
}
