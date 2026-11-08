import UIKit

/// タイムラインの行の種類。`FrameWork`で測った時間に付ける名前と、`SizingTrace`のスタックに残す名前に使う。
enum TimelineRowKind: String, CaseIterable {
    case status
    case pinned
    case gap
    case notification
    case unreadable
    case account
    case notificationRequest
    case search
    /// まだ行を出していないセル。
    case other = "row"
}

/// 中身に投稿の部品を持つ行の設定。
protocol SizingTraceable {
    var sizingParts: SizingTrace.Parts { get }
}

/// `SizingTrace`の関数を通ったあとで、実際に高さを測る相手。
@MainActor
protocol SizingMeasurable: AnyObject {
    func measureSizing(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes
}

/// セルの高さを測る呼び出しを、行の種類と部品ごとの名前の関数に通す。
/// TestFlightのクラッシュログからアプリのことが読めるのはスタックの関数名だけなので、高さを測っている間に落ちたときに、どの種類の行のどの部品で落ちたかを、そこから絞り込むために置く。
///
/// 関数名に載らない投稿のIDや実際の高さは残らない。
@MainActor
struct SizingTrace {
    struct Parts: OptionSet {
        let rawValue: Int

        static let spoiler = Parts(rawValue: 1 << 0)
        static let media = Parts(rawValue: 1 << 1)
        static let poll = Parts(rawValue: 1 << 2)
        static let card = Parts(rawValue: 1 << 3)
        static let embed = Parts(rawValue: 1 << 4)
        static let reactions = Parts(rawValue: 1 << 5)

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(spoiler: Bool, media: Bool, poll: Bool, card: Bool, embed: Bool, reactions: Bool) {
            var parts: Parts = []
            if spoiler { parts.insert(.spoiler) }
            if media { parts.insert(.media) }
            if poll { parts.insert(.poll) }
            if card { parts.insert(.card) }
            if embed { parts.insert(.embed) }
            if reactions { parts.insert(.reactions) }
            self = parts
        }
    }

    var row = TimelineRowKind.other
    var parts: Parts = []

    func run(on target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        switch row {
        case .status: Self.rowStatus(parts, target, attributes)
        case .pinned: Self.rowPinned(parts, target, attributes)
        case .gap: Self.rowGap(parts, target, attributes)
        case .notification: Self.rowNotification(parts, target, attributes)
        case .unreadable: Self.rowUnreadable(parts, target, attributes)
        case .account: Self.rowAccount(parts, target, attributes)
        case .notificationRequest: Self.rowNotificationRequest(parts, target, attributes)
        case .search: Self.rowSearch(parts, target, attributes)
        case .other: Self.rowOther(parts, target, attributes)
        }
    }

    /// - Parameter mark: 使わない。関数ごとに違う値を渡すと関数の中身が別物になり、リンカーが中身の同じ関数を1つにまとめて名前が消えるのを防げる。
    @inline(never) @_optimize(none)
    private static func next(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes, mark: Int) -> UICollectionViewLayoutAttributes {
        if rest.contains(.spoiler) { return partSpoiler(rest.subtracting(.spoiler), target, attributes) }
        if rest.contains(.media) { return partMedia(rest.subtracting(.media), target, attributes) }
        if rest.contains(.poll) { return partPoll(rest.subtracting(.poll), target, attributes) }
        if rest.contains(.card) { return partCard(rest.subtracting(.card), target, attributes) }
        if rest.contains(.embed) { return partEmbed(rest.subtracting(.embed), target, attributes) }
        if rest.contains(.reactions) { return partReactions(rest.subtracting(.reactions), target, attributes) }
        return target.measureSizing(attributes)
    }

    // Releaseのビルドでも、インライン化や末尾呼び出しの最適化で関数がスタックから消えないよう、最適化を止める。
    // クロージャを渡すと、最適化を止めていても呼び出し元に合わせた複製が作られて名前が変わるので、`SizingMeasurable`で受け取る。
    @inline(never) @_optimize(none) private static func rowStatus(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 1) }
    @inline(never) @_optimize(none) private static func rowPinned(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 2) }
    @inline(never) @_optimize(none) private static func rowGap(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 3) }
    @inline(never) @_optimize(none) private static func rowNotification(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 4) }
    @inline(never) @_optimize(none) private static func rowUnreadable(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 5) }
    @inline(never) @_optimize(none) private static func rowAccount(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 6) }
    @inline(never) @_optimize(none) private static func rowNotificationRequest(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 7) }
    @inline(never) @_optimize(none) private static func rowSearch(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 8) }
    @inline(never) @_optimize(none) private static func rowOther(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 9) }
    @inline(never) @_optimize(none) private static func partSpoiler(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 10) }
    @inline(never) @_optimize(none) private static func partMedia(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 11) }
    @inline(never) @_optimize(none) private static func partPoll(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 12) }
    @inline(never) @_optimize(none) private static func partCard(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 13) }
    @inline(never) @_optimize(none) private static func partEmbed(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 14) }
    @inline(never) @_optimize(none) private static func partReactions(_ rest: Parts, _ target: any SizingMeasurable, _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { next(rest, target, attributes, mark: 15) }
}

extension PostContentConfiguration: SizingTraceable {
    var sizingParts: SizingTrace.Parts {
        SizingTrace.Parts(spoiler: spoiler != nil, media: media != nil, poll: poll != nil, card: card != nil, embed: embed != nil, reactions: reactions != nil)
    }
}

extension NotificationContentConfiguration: SizingTraceable {
    var sizingParts: SizingTrace.Parts {
        SizingTrace.Parts(spoiler: body.spoiler != nil, media: body.media != nil, poll: body.poll != nil, card: body.card != nil, embed: body.embed != nil, reactions: body.reactions != nil)
    }
}
