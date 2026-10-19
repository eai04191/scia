import Foundation

/// ステータスバーの場所に1件ずつ流す通知。左に誰が何をしたか、右に対象の投稿の文頭か、画像だけの投稿ならサムネイルを出す。
/// 通知タブを開かなくても、反応が来たことに気づけるようにするため。
public struct StatusBarTickerItem: Sendable, Equatable, Identifiable {
    public let id: MastodonNotification.ID
    public let kind: MastodonNotification.Kind
    /// 通知のもとになる操作をしたアカウント。
    public let account: Account
    public let subject: Subject

    /// 右に出すもの。
    public enum Subject: Sendable, Equatable {
        /// 投稿の文頭。1段落にしてある。注意書きつきの投稿は、本文を見せないよう注意書きにする。
        case text(RichText)
        /// 文字のない投稿の、最初の添付ファイル。閲覧注意なら、サムネイルを覆う。
        case media(MediaAttachment, isSensitive: Bool)
        /// 対象の投稿がない通知（フォローなど）で、操作した人のアカウント名。`@`を付けてある。
        case handle(String)
        case none
    }

    public init(id: MastodonNotification.ID, kind: MastodonNotification.Kind, account: Account, subject: Subject) {
        self.id = id
        self.kind = kind
        self.account = account
        self.subject = subject
    }

    /// 種類を知らない通知は、何をされたかを出せないため流さない。
    /// - Parameter verdict: 通知の投稿に当てたサーバーのフィルターの判定。通知の一覧と同じく、警告なら本文を見せずにフィルターの名前を出し、ぼかしならサムネイルを覆う。
    public init?(_ notification: MastodonNotification, verdict: FilterVerdict = .none) {
        if case .other = notification.type { return nil }
        self.init(id: notification.id, kind: notification.type, account: notification.account, subject: Self.subject(of: notification, verdict: verdict))
    }

    private static func subject(of notification: MastodonNotification, verdict: FilterVerdict) -> Subject {
        guard let status = notification.status?.displayed else {
            return .handle("@\(notification.account.acct)")
        }
        if !verdict.warningTitles.isEmpty {
            return .text(RichText.plain("フィルター" + verdict.warningTitles.map { "「\($0)」" }.joined() + "に一致", emojis: []))
        }
        if !status.spoilerText.isEmpty {
            return .text(RichText.plain(status.spoilerText, emojis: status.emojis))
        }
        let text = RichText.status(status).singleLineExcerpt
        if !text.plainText.allSatisfy(\.isWhitespace) {
            return .text(text)
        }
        if let attachment = status.mediaAttachments.first(where: { $0.previewUrl != nil }) {
            return .media(attachment, isSensitive: status.sensitive || !verdict.mediaTitles.isEmpty)
        }
        return .none
    }
}

extension RichText {
    /// 狭い場所に1行で出すための文頭。段落と改行を空白でつなぎ、先頭に並ぶメンションを省く。
    /// 返信は宛先のメンションから始まり、狭い場所がそれだけで埋まるため。
    public var singleLineExcerpt: RichText {
        var inlines: [Inline] = []
        for block in blocks {
            if !inlines.isEmpty {
                inlines.append(.text(" ", []))
            }
            if let marker = block.listMarker {
                inlines.append(.text(marker, []))
            }
            inlines += block.inlines.map { inline in
                if case .lineBreak = inline { return .text(" ", []) }
                return inline
            }
        }
        while let first = inlines.first {
            switch first {
            case .link(_, .mention(_, _), _):
                inlines.removeFirst()
            case .text(let text, _) where text.allSatisfy(\.isWhitespace):
                inlines.removeFirst()
            case .text(let text, let style) where text.first?.isWhitespace == true:
                inlines[0] = .text(String(text.drop(while: \.isWhitespace)), style)
                return RichText(blocks: [Block(inlines: inlines)])
            default:
                return RichText(blocks: [Block(inlines: inlines)])
            }
        }
        return RichText(blocks: [Block(inlines: inlines)])
    }
}

/// ステータスバーに流すのを待っている通知の列と、1件を出しておく時間。
/// 待っている通知が多いほど1件の時間を縮め、続けざまに流す。古い反応がいつまでも流れ続けないようにするため。
public struct StatusBarTickerQueue<Item> {
    public struct Timing: Sendable, Equatable {
        /// 待っている通知がないときに、1件を出しておく秒数。
        public var duration: Double
        /// 縮めても、これより短くしない秒数。
        public var minimumDuration: Double
        /// 待っている通知1件ごとに、時間に掛ける割合。
        public var shrink: Double
        /// 待たせておく上限。超えたら古いものから捨てる。
        public var capacity: Int

        public init(duration: Double, minimumDuration: Double, shrink: Double, capacity: Int) {
            self.duration = duration
            self.minimumDuration = minimumDuration
            self.shrink = shrink
            self.capacity = capacity
        }
    }

    public var timing: Timing
    public private(set) var waiting: [Item] = []

    public init(timing: Timing) {
        self.timing = timing
    }

    public mutating func enqueue(_ item: Item) {
        waiting.append(item)
        let overflow = waiting.count - max(timing.capacity, 1)
        if overflow > 0 {
            waiting.removeFirst(overflow)
        }
    }

    public mutating func next() -> Item? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }

    public mutating func removeAll() {
        waiting.removeAll()
    }

    /// 今出している1件を、出してから何秒で次へ送るか。出している間に通知が届いたら、待っている数で測り直す。
    public var displayDuration: Double {
        max(timing.minimumDuration, timing.duration * pow(timing.shrink, Double(waiting.count)))
    }
}
