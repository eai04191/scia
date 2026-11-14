/// タップと長押しの操作を選べる対象。設定画面の見出しと、選んだ操作の設定を1か所に持つ。
/// どの部品がどの対象かは、docs/object-actions.mdの「対象」にある。主な操作（タップの既定）は、項目の種類の`primaryItem`で決まる。
public struct ObjectEntity<Item: ObjectActionItem & MenuItemPresentable> {
    /// 設定の画面に出す対象の名前。
    public let title: String
    public let actions: ReferenceWritableKeyPath<AppSettings, ObjectActions<Item>>

    /// `trigger`に、主な操作を選んでいるか。主な操作は、呼ぶ側が今のタップの処理で行う。
    @MainActor
    public func performsPrimary(_ trigger: ObjectTrigger, settings: AppSettings) -> Bool {
        settings[keyPath: actions].performsPrimary(trigger)
    }
}

@MainActor
extension ObjectEntity where Item == StatusMenuItem {
    /// タイムラインの投稿。
    public static var status: Self { ObjectEntity(title: "投稿", actions: \.statusActions) }
    /// 引用の囲み。アクションバーを出さないので、投稿とは別に選ぶ。
    public static var quotedStatus: Self { ObjectEntity(title: "引用の投稿", actions: \.quotedStatusActions) }
    public static var notification: Self { ObjectEntity(title: "通知", actions: \.notificationActions) }
}

@MainActor
extension ObjectEntity where Item == UserMenuItem {
    public static var user: Self { ObjectEntity(title: "ユーザー", actions: \.userActions) }
}

@MainActor
extension ObjectEntity where Item == LinkMenuItem {
    public static var link: Self { ObjectEntity(title: "リンク", actions: \.linkActions) }
}

/// Xの投稿の囲みのような、Mastodonの外のサービスの投稿。
@MainActor
extension ObjectEntity where Item == ExternalPostMenuItem {
    public static var externalPost: Self { ObjectEntity(title: "ほかのサービスの投稿", actions: \.externalPostActions) }
}

@MainActor
extension ObjectEntity where Item == HashtagMenuItem {
    public static var hashtag: Self { ObjectEntity(title: "ハッシュタグ", actions: \.hashtagActions) }
}

@MainActor
extension ObjectEntity where Item == ReactionMenuItem {
    public static var reaction: Self { ObjectEntity(title: "リアクション", actions: \.reactionActions) }
}

@MainActor
extension ObjectEntity where Item == MediaMenuItem {
    public static var media: Self { ObjectEntity(title: "メディア", actions: \.mediaActions) }
}
