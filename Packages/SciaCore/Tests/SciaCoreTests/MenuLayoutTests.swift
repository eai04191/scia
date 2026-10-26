import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// 既定で「その他」のすぐ後ろにある項目を持つ、テスト用のメニュー。
private enum TestMenuItem: String, MenuItemKind {
    case a
    case b
    case c
    case hiddenByDefault
    case delete

    static let defaultLayout = MenuLayout<TestMenuItem>(defaultElements: [
        .item(.a, isVisible: true),
        .item(.b, isVisible: true),
        .separator,
        .item(.c, isVisible: true),
        .item(.hiddenByDefault, isVisible: false),
        .more,
        .item(.delete, isVisible: true),
    ])
}

@Suite(.scratch)
@MainActor
struct MenuLayoutTests {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = TestScratch.defaults("MenuLayoutTests")
        return defaults
    }

    @Test func groupsSplitBySeparatorAndMore() {
        let groups = TestMenuItem.defaultLayout.groups

        #expect(groups.main.map(\.items) == [[.a, .b], [.c]])
        #expect(groups.more.map(\.items) == [[.delete]])
    }

    /// 非表示の項目を除いた結果、空になったまとまりは出さない。区切り線が続いても空のまとまりを作らない。
    @Test func emptyGroupsAreDropped() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .separator,
            .item(.a, isVisible: false),
            .separator,
            .separator,
            .item(.b, isVisible: true),
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: false),
        ])

        #expect(layout.groups.main.map(\.items) == [[.b, .c]])
        #expect(layout.groups.more.map(\.items) == [])
    }

    /// 横並びの区切り線は、並びの先頭や「その他」の境目のすぐ下でも、その下のまとまりを横に並べる。次の区切り線で横並びは終わる。
    @Test func rowSeparatorMakesFollowingGroupARow() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .rowSeparator,
            .item(.a, isVisible: true),
            .item(.b, isVisible: true),
            .separator,
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .rowSeparator,
            .item(.delete, isVisible: true),
        ])

        #expect(layout.groups.main == [.init([.a, .b], isRow: true), .init([.c])])
        #expect(layout.groups.more == [.init([.delete], isRow: true)])
    }

    /// 中身がすべて非表示の横並びのまとまりは出さず、横並びを次のまとまりに持ち越さない。
    @Test func emptyRowGroupDoesNotCarryOver() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .item(.a, isVisible: true),
            .rowSeparator,
            .item(.b, isVisible: false),
            .separator,
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: true),
        ])

        #expect(layout.groups.main == [.init([.a]), .init([.c])])
    }

    @Test func tokensRoundTripIncludingHiddenItemsAndSeparators() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .rowSeparator,
            .item(.delete, isVisible: true),
            .separator,
            .item(.c, isVisible: false),
            .more,
            .item(.a, isVisible: true),
            .separator,
            .item(.b, isVisible: true),
            .item(.hiddenByDefault, isVisible: true),
        ])

        #expect(MenuLayout<TestMenuItem>(tokens: layout.tokens) == layout)
    }

    /// 新しい項目は、既定で直前にある項目の、保存した並びでの位置の後ろに入る。動かした項目についていく。
    @Test func newItemFollowsItsDefaultPredecessor() {
        let saved = ["item:c", "separator", "item:a", "hidden:hiddenByDefault", "more", "item:delete"]

        let layout = MenuLayout<TestMenuItem>(tokens: saved)

        #expect(layout.elements == [
            .item(.c, isVisible: true),
            .separator,
            .item(.a, isVisible: true),
            .item(.b, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: true),
        ])
    }

    /// 区切り線は目印にしない。既定で区切り線の直後にある項目は、その前の項目の後ろに入る。
    @Test func separatorsAreNotAnchors() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:b", "item:a", "separator", "hidden:hiddenByDefault", "more", "item:delete"])

        #expect(layout.elements.prefix(3) == [.item(.b, isVisible: true), .item(.c, isVisible: true), .item(.a, isVisible: true)])
    }

    /// 既定で「その他」のすぐ後ろにある項目は、保存した並びでも「その他」の中の先頭に入る。
    @Test func newItemAfterMoreGoesIntoMore() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "more", "item:b", "item:c", "hidden:hiddenByDefault"])

        #expect(layout.groups.main.map(\.items) == [[.a]])
        #expect(layout.groups.more.map(\.items) == [[.delete, .b, .c]])
    }

    /// 新しい項目の表示は、項目ごとの既定に従う。
    @Test func newItemTakesDefaultVisibility() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "item:b", "item:c", "more", "item:delete"])

        #expect(layout.elements.contains(.item(.hiddenByDefault, isVisible: false)))
    }

    /// なくなった項目と、読めない値は捨てる。重なった項目は先に出たほうを残す。
    @Test func unknownAndDuplicateTokensAreDropped() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "item:removed", "bogus", "hidden:a", "item:b", "item:c", "hidden:hiddenByDefault", "more", "more", "item:delete"])

        #expect(layout == TestMenuItem.defaultLayout.withoutSeparators)
    }

    /// 既定の並びで先頭の項目が足りなければ、並びの先頭に入る。
    @Test func missingFirstItemGoesToTop() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:b", "item:c", "hidden:hiddenByDefault", "more", "item:delete"])

        #expect(layout.elements.first == .item(.a, isVisible: true))
    }

    /// 既定のメニューはよく押す項目だけにし、何のための操作かでまとまりを分ける。返信・お気に入り・ブーストは横に並べる。
    /// たまにしか使わない項目と取り消せない操作は「その他」に入れ、ほかの設定で代わりがきく公開範囲を選んでブーストは隠す。
    @Test func statusMenuDefaultGroupsItemsByPurpose() {
        let groups = StatusMenuItem.defaultLayout.groups

        #expect(groups.main.map(\.isRow) == [true, false, false, false, false])
        #expect(groups.main.map(\.items) == [
            [.reply, .favourite, .reblog],
            [.edit, .bookmark, .quote],
            [.copyLink, .copyText, .share, .openInBrowser],
            [.systemTranslate],
            [.notifyingUser, .author, .booster, .hashtags],
        ])
        #expect(groups.more.map(\.items) == [[.editHistory, .favouritedBy, .rebloggedBy, .hideMedia, .customEmojis], [.muteConversation, .pin], [.dismissNotification, .delete]])
        #expect(StatusMenuItem.defaultLayout.elements.contains(.item(.reblogWithVisibility, isVisible: false)))
    }

    /// ユーザーのメニューは、開く・書く操作、フォロー、持ち出す操作でまとまりを分ける。開く場所を選んで開く2つは隠しておく。
    /// たまにしか使わないフォローの設定と、ミュート、ブロック、通報は「その他」に入れる。
    @Test func userMenuDefaultGroupsItemsByPurpose() {
        let layout = UserMenuItem.defaultLayout

        #expect(layout.groups.main.map(\.items) == [[.profile, .mention], [.follow], [.copyHandle, .copyLink, .share, .openInBrowser]])
        #expect(layout.groups.more.map(\.items) == [[.showReblogs, .notify], [.mute, .block, .report]])
        #expect([UserMenuItem.openInDefaultBrowser, .openInAppSafari].allSatisfy { layout.elements.contains(.item($0, isVisible: false)) })
    }

    /// 関係で中身が変わる項目を1つでも出していれば、メニューを開いたときに関係を読む。「その他」の中にあっても読む。
    /// 通報だけなら、自分かどうかはIDで決まるので読まない。
    @Test func userMenuNeedsRelationshipOnlyWithRelationDependentItems() {
        func layout(_ tokens: [String]) -> MenuLayout<UserMenuItem>.Groups {
            MenuLayout<UserMenuItem>(elements: MenuLayout<UserMenuItem>(tokens: tokens).elements.map { element in
                guard case .item(let item, _) = element else { return element }
                return .item(item, isVisible: tokens.contains("item:\(item.rawValue)"))
            }).groups
        }

        #expect(UserMenuItem.defaultLayout.groups.needsRelationship)
        #expect(layout(["item:profile", "more", "item:mute"]).needsRelationship)
        #expect(!layout(["item:profile", "item:copyLink", "more", "item:report"]).needsRelationship)
    }

    /// メンション、フォロー、ハンドルをコピーを足す前に保存したユーザーのメニューでも、3つはプロフィールの後ろに出る。
    /// 既定で「その他」の先頭にあるフォローの設定、ミュート、ブロック、通報は、「その他」に入る。
    @Test func savedUserMenuGainsNewItemsAfterProfile() {
        let saved = MenuLayout<UserMenuItem>(tokens: ["item:profile", "item:copyLink", "item:share", "more"])

        #expect(saved.groups.main.map(\.items) == [[.profile, .mention, .follow, .copyHandle, .copyLink, .share, .openInBrowser]])
        #expect(saved.groups.more.map(\.items) == [[.showReblogs, .notify, .mute, .block, .report]])
    }

    /// 開く場所を選んで開く2つを足す前に保存した投稿のメニューでも、2つはブラウザで開くのすぐ後ろに、隠れて入る。
    @Test func savedStatusMenuGainsHiddenBrowserChoicesAfterOpenInBrowser() {
        let saved = MenuLayout<StatusMenuItem>(tokens: StatusMenuItem.defaultLayout.tokens.filter { !$0.hasSuffix(":openInDefaultBrowser") && !$0.hasSuffix(":openInAppSafari") })
        let index = saved.elements.firstIndex(of: .item(.openInBrowser, isVisible: true))

        #expect(index.map { Array(saved.elements[($0 + 1)...($0 + 2)]) } == [.item(.openInDefaultBrowser, isVisible: false), .item(.openInAppSafari, isVisible: false)])
        #expect(saved.groups == StatusMenuItem.defaultLayout.groups)
    }

    /// 本文のリンクのメニューは、設定を足す前の決め打ちのメニューと同じ並びにする。ハッシュタグのメニューは、その前にアプリで開く2つとミュートを置く。開く場所を選んで開く2つは隠しておく。
    /// リンクのメニューには、あとから足した「プロフィールとして開く」が「ブラウザで開く」の下に入る。
    @Test func linkAndHashtagMenuDefaultsMatchMenuBeforeCustomization() {
        #expect(LinkMenuItem.defaultLayout.groups.main.map(\.items) == [[.openInBrowser, .openAsProfile, .copyLink, .share]])
        #expect(LinkMenuItem.defaultLayout.groups.more.map(\.items).isEmpty)
        #expect(HashtagMenuItem.defaultLayout.groups.main.map(\.items) == [[.timeline, .accountStatuses], [.mute], [.openInBrowser, .copyLink, .share]])
        #expect(HashtagMenuItem.defaultLayout.groups.more.map(\.items).isEmpty)
    }

    /// 「プロフィールとして開く」を足す前に保存したリンクのメニューでも、「ブラウザで開く」の下に出る。
    @Test func savedLinkMenuGainsOpenAsProfileAfterOpenInBrowser() {
        let saved = MenuLayout<LinkMenuItem>(tokens: [
            "item:openInBrowser", "hidden:openInDefaultBrowser", "hidden:openInAppSafari", "item:copyLink", "item:share", "more",
        ])

        #expect(saved.groups.main.map(\.items) == [[.openInBrowser, .openAsProfile, .copyLink, .share]])
    }

    /// タイムラインを開く2つを足す前に保存したハッシュタグのメニューでも、2つは先頭に出る。
    @Test func savedHashtagMenuGainsTimelineItemsAtTop() {
        let saved = MenuLayout<HashtagMenuItem>(tokens: ["item:openInBrowser", "hidden:openInDefaultBrowser", "hidden:openInAppSafari", "item:copyLink", "item:share", "more"])
        #expect(saved.groups.main.flatMap(\.items).prefix(2) == [.timeline, .accountStatuses])
    }

    /// リンクをコピーと共有を足す前に保存したユーザーのメニューでも、2つはプロフィールの後ろに出る。
    @Test func savedUserMenuGainsCopyLinkAndShareAfterProfile() {
        let saved = MenuLayout<UserMenuItem>(tokens: ["more", "item:profile"])

        #expect(saved.groups.main.map(\.items).isEmpty)
        #expect(saved.groups.more.map(\.items) == [[.showReblogs, .notify, .mute, .block, .report, .profile, .mention, .follow, .copyHandle, .copyLink, .share, .openInBrowser]])
    }

    /// ブックマークを足す前に保存した投稿のメニューでも、ブックマークは編集の後ろに、表示されて入る。
    @Test func savedStatusMenuGainsVisibleBookmarkAfterEdit() {
        let saved = MenuLayout<StatusMenuItem>(tokens: StatusMenuItem.defaultLayout.tokens.filter { !$0.hasSuffix(":bookmark") })
        let index = saved.elements.firstIndex(of: .item(.edit, isVisible: true))

        #expect(index.map { saved.elements[$0 + 1] } == .item(.bookmark, isVisible: true))
    }

    /// 引用を足す前に保存した投稿のメニューでも、引用はブックマークの後ろに、表示されて入る。
    @Test func savedStatusMenuGainsVisibleQuoteAfterBookmark() {
        let saved = MenuLayout<StatusMenuItem>(tokens: StatusMenuItem.defaultLayout.tokens.filter { !$0.hasSuffix(":quote") })
        let index = saved.elements.firstIndex(of: .item(.bookmark, isVisible: true))

        #expect(index.map { saved.elements[$0 + 1] } == .item(.quote, isVisible: true))
    }

    /// 編集と削除を足す前に保存した並びでも、編集はブーストの後ろに、削除は「その他」に入る。
    @Test func savedStatusMenuGainsEditAndDelete() {
        let saved = MenuLayout<StatusMenuItem>(tokens: ["item:reblog", "item:reply", "item:favourite", "separator", "item:copyLink", "more", "hidden:share"])

        #expect(saved.groups.main.map(\.items).first == [.reblog, .edit, .bookmark, .quote, .reply, .favourite])
        // 編集履歴は既定で「その他」の先頭にあるため、保存した並びでも「その他」の先頭に入り、削除までの項目がその後ろに続く。
        // 共有を「その他」に入れた並びなので、共有の後ろに来るブラウザで開くなども、その後ろに続く。
        #expect(saved.groups.more.map(\.items).first.map { Array($0.prefix(9)) } == [.editHistory, .favouritedBy, .rebloggedBy, .hideMedia, .customEmojis, .muteConversation, .pin, .dismissNotification, .delete])
    }

    @Test func appSettingsPersistsMenuLayouts() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).statusMenuLayout == StatusMenuItem.defaultLayout)

        let changed = MenuLayout<StatusMenuItem>(elements: [.item(.share, isVisible: true), .more, .item(.reply, isVisible: false)])
        AppSettings(defaults: defaults).statusMenuLayout = changed

        let restored = AppSettings(defaults: defaults).statusMenuLayout
        #expect(restored == changed)
        #expect(restored.groups.main.map(\.items).first?.first == .share)
    }

    /// メディアのメニューは、開く・共有・保存、読む、持ち出す、投稿の順にまとまりを分け、メディアの情報は「その他」に入れる。
    @Test func mediaMenuDefaultGroupsItemsByPurpose() {
        let groups = MediaMenuItem.defaultLayout.groups

        #expect(groups.main.map(\.items) == [
            [.open, .share, .saveToPhotos],
            [.altText, .translateText],
            [.copyLink, .openInBrowser],
            [.status],
        ])
        #expect(groups.more.map(\.items) == [[.info]])
    }

    @Test func appSettingsPersistsMediaMenuLayout() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).mediaMenuLayout == MediaMenuItem.defaultLayout)

        let media = MenuLayout<MediaMenuItem>(elements: [.item(.saveToPhotos, isVisible: true), .more, .item(.open, isVisible: false)])
        AppSettings(defaults: defaults).mediaMenuLayout = media

        #expect(AppSettings(defaults: defaults).mediaMenuLayout == media)
    }

    @Test func appSettingsPersistsLinkAndHashtagMenuLayouts() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).linkMenuLayout == LinkMenuItem.defaultLayout)
        #expect(AppSettings(defaults: defaults).hashtagMenuLayout == HashtagMenuItem.defaultLayout)

        let link = MenuLayout<LinkMenuItem>(elements: [.item(.share, isVisible: true), .more, .item(.openInBrowser, isVisible: false)])
        let hashtag = MenuLayout<HashtagMenuItem>(elements: [.item(.copyLink, isVisible: true), .separator, .item(.openInBrowser, isVisible: false), .more])
        let settings = AppSettings(defaults: defaults)
        settings.linkMenuLayout = link
        settings.hashtagMenuLayout = hashtag

        let restored = AppSettings(defaults: defaults)
        #expect(restored.linkMenuLayout == link)
        #expect(restored.hashtagMenuLayout == hashtag)
    }
}

private extension MenuLayout where Item == TestMenuItem {
    /// 既定の並びから区切り線を除いたもの。
    var withoutSeparators: MenuLayout<TestMenuItem> {
        MenuLayout(elements: elements.filter { $0 != .separator })
    }
}
