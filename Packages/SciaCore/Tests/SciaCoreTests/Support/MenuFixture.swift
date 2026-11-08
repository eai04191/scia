import SciaCore

/// テストで組むメニューの並び。既定の並び（menu-defaults.json）はエディターで並べ替えるたびに変わるため、メニューの組み立てを確かめるテストは既定の並びに頼らず、この並びを渡す。
/// 中身は、作った時点の既定の並びをコピーしたもの。既定の並びに合わせて直さない。
/// アプリのテスト（SciaTests）もproject.ymlでこのファイルを読み込む。SciaTestingに置くとSciaCoreに依存させることになり、テストのバンドルにSciaCoreが2つ入って落ちる。
enum MenuFixture {
    static let status = MenuLayout<StatusMenuItem>(tokens: [
        "row",
        "item:reply",
        "item:reblog",
        "item:favourite",
        "separator",
        "item:bookmark",
        "item:quote",
        "hidden:reblogWithVisibility",
        "separator",
        "item:share",
        "item:copyLink",
        "item:copyText",
        "item:selectText",
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "separator",
        "hidden:openThread",
        "item:systemTranslate",
        "item:toggleTranslation",
        "separator",
        "item:notifyingUser",
        "item:author",
        "item:booster",
        "hidden:mentionedUsers",
        "item:hashtags",
        "separator",
        "item:edit",
        "item:dismissNotification",
        "item:delete",
        "more",
        "item:select",
        "separator",
        "item:editHistory",
        "item:favouritedBy",
        "item:rebloggedBy",
        "separator",
        "item:hideMedia",
        "item:customEmojis",
        "hidden:apiResponse",
        "separator",
        "item:muteConversation",
        "item:pin",
        "item:redraft",
        "separator",
        "item:customize",
    ])

    static let user = MenuLayout<UserMenuItem>(tokens: [
        "item:profile",
        "item:mention",
        "separator",
        "item:follow",
        "item:addToList",
        "separator",
        "item:copyHandle",
        "item:copyLink",
        "item:share",
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "separator",
        "item:mute",
        "item:block",
        "item:report",
        "more",
        "item:copyUsername",
        "item:copyServer",
        "separator",
        "item:note",
        "item:showReblogs",
        "item:notify",
        "item:endorse",
        "separator",
        "item:customize",
    ])

    static let link = MenuLayout<LinkMenuItem>(tokens: [
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "item:openAsProfile",
        "separator",
        "item:copyLink",
        "item:share",
        "more",
        "item:customize",
    ])

    static let externalPost = MenuLayout<ExternalPostMenuItem>(tokens: [
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "separator",
        "item:copyLink",
        "item:copyText",
        "item:share",
        "separator",
        "item:systemTranslate",
        "more",
        "item:customize",
    ])

    static let profileText = MenuLayout<ProfileTextMenuItem>(tokens: [
        "item:copyText",
        "item:copyLabel",
        "separator",
        "item:systemTranslate",
        "separator",
        "item:customEmojis",
        "more",
        "item:customize",
    ])

    static let hashtag = MenuLayout<HashtagMenuItem>(tokens: [
        "item:timeline",
        "item:accountStatuses",
        "separator",
        "item:copyLink",
        "item:share",
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "separator",
        "item:mute",
        "more",
        "item:feature",
        "separator",
        "item:customize",
    ])

    static let reaction = MenuLayout<ReactionMenuItem>(tokens: [
        "item:toggle",
        "item:reactedBy",
        "item:open",
        "more",
        "item:customize",
    ])

    static let media = MenuLayout<MediaMenuItem>(tokens: [
        "item:open",
        "item:share",
        "item:saveToPhotos",
        "separator",
        "item:altText",
        "item:translateText",
        "separator",
        "item:copyLink",
        "item:openInBrowser",
        "hidden:openInDefaultBrowser",
        "hidden:openInAppSafari",
        "separator",
        "item:status",
        "more",
        "item:info",
        "separator",
        "item:customize",
    ])
}

extension AppSettings {
    /// メニューの並びを、すべて`MenuFixture`にする。
    func useMenuFixtures() {
        statusMenuLayout = MenuFixture.status
        userMenuLayout = MenuFixture.user
        linkMenuLayout = MenuFixture.link
        externalPostMenuLayout = MenuFixture.externalPost
        profileTextMenuLayout = MenuFixture.profileText
        hashtagMenuLayout = MenuFixture.hashtag
        reactionMenuLayout = MenuFixture.reaction
        mediaMenuLayout = MenuFixture.media
    }
}
