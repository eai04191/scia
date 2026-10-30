/// 通知の種類ごとの見た目と文言。
public struct NotificationAppearance: Sendable {
    /// 操作したアカウントの名前の前後に置く文言。
    public struct Phrase: Sendable {
        public let before: String
        public let after: String
        public let includesName: Bool

        public static func named(_ after: String) -> Phrase {
            named("", after)
        }

        public static func named(_ before: String, _ after: String) -> Phrase {
            Phrase(before: before, after: after, includesName: true)
        }

        public static func unnamed(_ text: String) -> Phrase {
            Phrase(before: text, after: "", includesName: false)
        }
    }

    /// 記号の色。描く側が、その画面の色に置き換える。
    public enum Tint: Sendable {
        /// アプリの色。
        case accent
        case green
        case orange
        /// 控えめな文字の色。
        case secondary
    }

    public let symbolName: String
    public let tint: Tint
    public let phrase: Phrase

    public init(_ kind: MastodonNotification.Kind) {
        (symbolName, tint, phrase) = switch kind {
        case .mention: ("at", .accent, .named("からのメンション"))
        case .status: ("bell.fill", .accent, .named("が投稿しました"))
        case .reblog: ("arrow.2.squarepath", .green, .named("がブーストしました"))
        case .favourite: ("star.fill", .orange, .named("がお気に入りに登録しました"))
        case .follow: ("person.fill.badge.plus", .accent, .named("にフォローされました"))
        case .followRequest: ("person.badge.clock.fill", .accent, .named("からフォローリクエストが届きました"))
        case .poll: ("chart.bar.fill", .accent, .unnamed("投票が終了しました"))
        case .update: ("pencil", .secondary, .named("がブーストした投稿を編集しました"))
        case .quote: ("quote.bubble.fill", .accent, .named("が引用しました"))
        case .quotedUpdate: ("pencil", .secondary, .named("引用した投稿を", "が編集しました"))
        // 種類を知らない通知も、誰からかだけは分かるように出す。
        case .other(let rawValue): ("bell", .secondary, .named("からの通知（\(rawValue)）"))
        }
    }
}
