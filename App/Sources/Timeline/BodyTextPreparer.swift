import SciaCore
import UIKit

/// 一覧の投稿の本文を、画面に入る前に、メインスレッドの外で文字列にしてTextKit 2で並べておく。
/// 初めて画面に入る行で、本文のHTMLを読んで文字列にし、並べる処理が、長い本文ではフレームを落としていたため。
/// 行を組み立てるときは、作っておいた文字列と並びを、今の描き方と同じときだけ使い、違えばその場で作る。
@MainActor
final class BodyTextPreparer {
    /// 作っておいた本文。
    struct Prepared {
        let text: NSAttributedString
        /// 並べた結果。本文の幅が分からないうちに作ったときはnil。
        let layout: PreparedTextLayout?
    }

    /// 本文の文字列を決める、投稿の中身。
    private struct Source: Equatable, Sendable {
        let content: String
        let mentions: [Mention]
        let tags: [Tag]
        let emojis: [CustomEmoji]
        let hasQuote: Bool

        init(_ status: Status) {
            content = status.content
            mentions = status.mentions
            tags = status.tags
            emojis = status.emojis
            hasQuote = status.quote != nil
        }
    }

    /// メインスレッドの外へ渡す、1件の本文の材料。
    private struct Request: Sendable {
        let id: Status.ID
        let status: Status
        let source: Source
        /// カスタム絵文字の画像を写し取った描き手。
        let renderer: RichTextRenderer
        let geometry: Geometry?
        let truncation: BodyTruncation?
    }

    /// 本文のラベルの値と幅。
    struct Geometry: Equatable, Sendable {
        let style: TextKitLabelLayout.Style
        let width: CGFloat
    }

    private final class Entry {
        let source: Source
        let renderer: RichTextRenderer
        /// 本文に出てくるカスタム絵文字の画像のURLと、描いた高さのピクセル数。
        let emojiPixelHeights: [URL: Int]
        let text: NSAttributedString
        let layout: PreparedTextLayout?

        init(source: Source, renderer: RichTextRenderer, emojiPixelHeights: [URL: Int], text: NSAttributedString, layout: PreparedTextLayout?) {
            self.source = source
            self.renderer = renderer
            self.emojiPixelHeights = emojiPixelHeights
            self.text = text
            self.layout = layout
        }

        /// `status`の本文を`renderer`で描いたときと同じか。本文の中身、描き方、カスタム絵文字の画像の状態を比べる。
        /// 絵文字は描いた高さで求めるので、絵文字だけの本文のように大きく描く絵文字は、ここでその高さの読み直しが始まる。
        @MainActor
        func isCurrent(for status: Status, renderer: RichTextRenderer) -> Bool {
            source == Source(status) && self.renderer.hasSameStyle(as: renderer)
                && emojiPixelHeights.allSatisfy { url, height in
                    renderer.emojiState(of: url, pixelHeight: height) == self.renderer.emojiState(of: url, pixelHeight: height)
                }
        }
    }

    /// 持っておく本文の数。画面の前後に先に作る分と、画面に出ている分が入る数にし、古いものから捨てる。
    private static let capacity = 120

    private var entries: [Status.ID: Entry] = [:]
    /// 作った順。古いものから捨てる。
    private var order: [Status.ID] = []
    /// これから作る本文。新しく頼まれたものを先に作る。
    private var pending: [Request] = []
    private var worker: Task<Void, Never>?

    isolated deinit {
        worker?.cancel()
    }

    /// `status`の本文を、作っておいた文字列と並びで返す。作っていないか、`renderer`の描き方や、カスタム絵文字の画像の状態が作ったときと違えばnil。
    func prepared(for status: Status, renderer: RichTextRenderer) -> Prepared? {
        guard let entry = entries[status.id], entry.isCurrent(for: status, renderer: renderer) else { return nil }
        return Prepared(text: entry.text, layout: entry.layout)
    }

    /// `statuses`の本文を、まだなければ作り始める。前に頼んでまだ作っていないものより先に作る。
    /// - Parameters:
    ///   - renderer: 投稿の本文の描き手を返す。行を組み立てるときと同じ描き手にする。
    ///   - geometry: 本文のラベルの値と幅。分からなければnilにし、文字列だけを作る。
    ///   - truncation: 投稿の長い本文を切る決まりを返す。
    func prepare(_ statuses: [Status], renderer: (Status) -> RichTextRenderer, geometry: Geometry?, truncation: (Status) -> BodyTruncation?) {
        var requests: [Request] = []
        for status in statuses {
            let made = renderer(status)
            // カスタム絵文字の画像が届いたり読めなかったりして描き方が変わった本文は、作り直す。
            if let entry = entries[status.id], entry.isCurrent(for: status, renderer: made),
               entry.layout.map({ $0.style == geometry?.style && $0.width == geometry?.width }) ?? (geometry == nil) {
                continue
            }
            requests.append(Request(
                id: status.id,
                status: status,
                source: Source(status),
                renderer: made.withEmojiSnapshot(of: status.emojis.map(\.staticUrl)),
                geometry: geometry,
                truncation: truncation(status)
            ))
        }
        guard !requests.isEmpty else { return }
        let requested = Set(requests.map(\.id))
        pending = requests + pending.filter { !requested.contains($0.id) }
        // 速く流すと、前に頼んだものは画面を過ぎていて要らなくなる。古いものは作らずに捨てる。
        if pending.count > Self.capacity / 2 {
            pending.removeLast(pending.count - Self.capacity / 2)
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        // 作っている間は持ち主を持たない。一覧が閉じられたら、作り終えたものは捨てて止まる。
        worker = Task(.withoutRequests) { [weak self] in
            while !Task.isCancelled, let request = self?.nextRequest() {
                let entry = await Self.make(request)
                guard !Task.isCancelled else { break }
                self?.store(entry, for: request.id)
            }
            self?.worker = nil
        }
    }

    private func nextRequest() -> Request? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func store(_ entry: Entry, for id: Status.ID) {
        if entries.updateValue(entry, forKey: id) != nil {
            order.removeAll { $0 == id }
        }
        order.append(id)
        if order.count > Self.capacity {
            let removed = order.removeFirst()
            entries[removed] = nil
        }
    }

    /// 本文を文字列にして並べる。メインスレッドの外で走らせ、作ったものは返したあとメインスレッドだけが触る。
    @concurrent
    private nonisolated static func make(_ request: Request) async -> sending Entry {
        let richText = RichText.status(request.status)
        let text = request.renderer.render(richText)
        let layout = request.geometry.map {
            PreparedTextLayout(source: text, style: $0.style, width: $0.width, truncation: request.truncation)
        }
        return Entry(
            source: request.source,
            renderer: request.renderer,
            emojiPixelHeights: emojiPixelHeights(in: text, urls: RichTextRenderer.emojiURLs(in: richText), scale: request.renderer.displayScale),
            text: text,
            layout: layout
        )
    }

    /// 本文の絵文字の画像のURLごとの、描いた高さのピクセル数。同じ絵文字を違う高さで描いていれば、高いほう。
    /// 画像を置かずに文字で描いた絵文字は、ストアの既定の高さにする。
    private nonisolated static func emojiPixelHeights(in text: NSAttributedString, urls: Set<URL>, scale: CGFloat) -> [URL: Int] {
        var heights = Dictionary(uniqueKeysWithValues: urls.map { ($0, EmojiImageStore<UIImage>.pixelHeight) })
        text.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let emoji = value as? CustomEmoji,
                  let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
            else { return }
            let height = RichTextRenderer.pixelHeight(of: attachment.bounds.height, scale: scale)
            heights[emoji.staticUrl] = max(heights[emoji.staticUrl] ?? 0, height)
        }
        return heights
    }
}
