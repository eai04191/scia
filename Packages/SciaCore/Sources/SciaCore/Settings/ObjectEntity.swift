/// タップと長押しの操作を選べる対象。設定画面の見出しと、選んだ操作の設定を1か所に持つ。
/// どの部品がどの対象かは、docs/object-actions.mdの「対象」にある。主な操作（タップの既定）は、項目の種類の`primaryItem`で決まる。
public struct ObjectEntity<Item: ObjectActionItem & MenuItemPresentable> {
    /// この対象の操作の設定の画面。
    public let page: SettingsPage
    public let actions: ReferenceWritableKeyPath<AppSettings, ObjectActions<Item>>

    /// 設定の画面に出す対象の名前。
    public var title: String { page.title }

    /// `trigger`に、主な操作を選んでいるか。主な操作は、呼ぶ側が今のタップの処理で行う。
    @MainActor
    public func performsPrimary(_ trigger: ObjectTrigger, settings: AppSettings) -> Bool {
        settings[keyPath: actions].performsPrimary(trigger)
    }
}

@MainActor
extension ObjectEntity where Item == StatusMenuItem {
    /// タイムラインの投稿。
    public static var status: Self { ObjectEntity(page: .statusActions, actions: \.statusActions) }
    /// 引用の囲み。アクションバーを出さないので、投稿とは別に選ぶ。
    public static var quotedStatus: Self { ObjectEntity(page: .quotedStatusActions, actions: \.quotedStatusActions) }
    public static var notification: Self { ObjectEntity(page: .notificationActions, actions: \.notificationActions) }
}

@MainActor
extension ObjectEntity where Item == UserMenuItem {
    public static var user: Self { ObjectEntity(page: .userActions, actions: \.userActions) }
}

@MainActor
extension ObjectEntity where Item == LinkMenuItem {
    public static var link: Self { ObjectEntity(page: .linkActions, actions: \.linkActions) }
}

/// Xの投稿の囲みのような、Mastodonの外のサービスの投稿。
@MainActor
extension ObjectEntity where Item == ExternalPostMenuItem {
    public static var externalPost: Self { ObjectEntity(page: .externalPostActions, actions: \.externalPostActions) }
}

@MainActor
extension ObjectEntity where Item == HashtagMenuItem {
    public static var hashtag: Self { ObjectEntity(page: .hashtagActions, actions: \.hashtagActions) }
}

@MainActor
extension ObjectEntity where Item == ReactionMenuItem {
    public static var reaction: Self { ObjectEntity(page: .reactionActions, actions: \.reactionActions) }
}

@MainActor
extension ObjectEntity where Item == MediaMenuItem {
    public static var media: Self { ObjectEntity(page: .mediaActions, actions: \.mediaActions) }
}
