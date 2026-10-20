import Foundation

extension RichText {
    /// fxtwitterの`raw_text`から、URL、ハッシュタグ、メンションをリンクにした本文を作る。
    ///
    /// URLは、Xと同じく展開した先へのリンクにし、本文には短い形を見せる。ハッシュタグとメンションは、Mastodonのものではないため、Xのページへのリンクにする。
    /// 位置は、通常の投稿も長い投稿も、Unicodeのスカラー値で数えている（絵文字を含む投稿の応答で確かめた）。
    /// 位置は文字参照のままの本文で数えているため、切り分けてから文字参照を戻す。
    /// `media`のfacetは、長い投稿では本文にない位置を指すため使わない。通常の投稿では見せる範囲の外にあるため、使わなくても困らない。
    init(xPost raw: FxTwitterResponse.RawText) {
        let scalars = Array(raw.text.unicodeScalars)
        // 見せる範囲の始まりは使わない。返信の先頭の宛先のメンションは、Xでは「返信先」として本文の外に出るが、囲みには返信先の表示がないため、本文に残してリンクにする。
        // 長い投稿の見せる範囲はfxtwitterが本文のUTF-16の長さで作るため、スカラー値で数えた長さを超えることがある。そのときは全文を見せる。
        let end = min(raw.displayTextRange?.last ?? scalars.count, scalars.count)
        var inlines: [Inline] = []
        var position = 0

        func appendText(upTo index: Int) {
            guard position < index else { return }
            inlines.append(.text(HTMLEntities.decode(Self.string(scalars[position..<index])), []))
        }

        let links = raw.facets
            .compactMap { facet in Self.link(of: facet, in: scalars, end: end).map { (facet.indices[0], facet.indices[1], $0) } }
            .sorted { $0.0 < $1.0 }
        for (start, linkEnd, link) in links where position <= start {
            appendText(upTo: start)
            inlines.append(link)
            position = linkEnd
        }
        appendText(upTo: end)
        self.init(blocks: [Block(inlines: inlines)])
    }

    /// facetのリンク。リンクにしない種類や、本文の見せる範囲に収まらない位置ならnil。
    private static func link(of facet: FxTwitterResponse.Facet, in scalars: [Unicode.Scalar], end: Int) -> Inline? {
        guard facet.indices.count == 2, let start = facet.indices.first, let last = facet.indices.last,
              0 <= start, start < last, last <= end
        else { return nil }
        let text = HTMLEntities.decode(string(scalars[start..<last]))
        let xPage = URL(string: "https://x.com")
        switch facet.type {
        case "url":
            guard let url = (facet.replacement ?? facet.original).flatMap(URL.init(string:)) else { return nil }
            return .link(facet.display ?? text, .url(url), [])
        case "hashtag":
            guard let name = facet.original, let url = xPage?.appending(path: "hashtag").appending(path: name) else { return nil }
            return .link(text, .url(url), [])
        case "mention":
            guard let name = facet.original, let url = xPage?.appending(path: name) else { return nil }
            return .link(text, .url(url), [])
        default:
            return nil
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
