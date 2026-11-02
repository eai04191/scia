import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
struct TabPlacementTests {
    /// 既定は、切り替えタブを使わず、5つを直接並べる。
    @Test func defaultPlacesEveryTimelineDirectly() {
        let placement = TabPlacement(layout: TabItem.defaultLayout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home, .local, .federated, .notifications, .search])
        #expect(placement.switchable.isEmpty)
    }

    /// ブックマーク、お気に入り、予約投稿は既定で無効にし、有効にすると切り替えタブに入る。保存済みの並びにも同じ位置で差し込む。
    /// 検索は既定で有効なので、保存済みの並びでも通知の後ろに有効で差し込む。
    @Test func savedListsStartDisabledBelowBoundary() {
        let saved = MenuLayout<TabItem>(tokens: ["item:home", "item:notifications", "more", "item:local", "item:federated"])
        #expect(saved.tokens == ["item:home", "item:notifications", "item:search", "more", "hidden:bookmarks", "hidden:favourites", "hidden:scheduled", "item:local", "item:federated"])
        #expect(TabPlacement(layout: saved, tabBarCapacity: TabPlacement.compactTabBarCapacity).location(of: .bookmarks) == .disabled)
        #expect(TabPlacement(layout: saved, tabBarCapacity: TabPlacement.compactTabBarCapacity).location(of: .scheduled) == .disabled)

        let enabled = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:bookmarks"])
        #expect(TabPlacement(layout: enabled, tabBarCapacity: TabPlacement.compactTabBarCapacity).location(of: .bookmarks) == .switchTab)
    }

    @Test func itemsBelowBoundaryGoToSwitchTabInOrder() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .more,
            .item(.federated, isVisible: true),
            .item(.local, isVisible: true),
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home, .notifications])
        #expect(placement.switchable == [.federated, .local])
        #expect(placement.location(of: .notifications) == .tab)
        #expect(placement.location(of: .local) == .switchTab)
    }

    /// 境目より上の項目がタブバーに入りきらなければ、入りきらない分を切り替えタブの先頭にまとめる。
    /// UIKitの「その他」を出すと、選んでいるタブと見えている画面がずれ、ほかのタブへ移れなくなるため。
    @Test func overflowingTabsGoToSwitchTabBeforeItemsBelowBoundary() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.bookmarks, isVisible: true),
            .item(.favourites, isVisible: true),
            .more,
            .item(.list(id: "1", title: "見る"), isVisible: true),
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home, .notifications, .local, .federated])
        #expect(placement.switchable == [.bookmarks, .favourites, .list(id: "1", title: "見る")])
        #expect(placement.location(of: .favourites) == .switchTab)
    }

    /// 切り替えタブがいらなければ、タブバーに入る数まで直接並べる。
    @Test func fiveTabsFitWithoutSwitchTab() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.bookmarks, isVisible: true),
            .more,
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home, .notifications, .local, .federated, .bookmarks])
        #expect(placement.switchable.isEmpty)
    }

    /// 境目より下に項目があれば、切り替えタブの分を空けるので、5つ目も切り替えタブに入る。
    @Test func fiveTabsWithItemsBelowBoundaryLeaveRoomForSwitchTab() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.bookmarks, isVisible: true),
            .more,
            .item(.favourites, isVisible: true),
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home, .notifications, .local, .federated])
        #expect(placement.switchable == [.bookmarks, .favourites])
    }

    /// 数を限らないタブバーでは、境目より下の有効な項目も直接並べ、切り替えタブを出さない。
    @Test func unlimitedTabBarPlacesItemsBelowBoundaryDirectly() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.search, isVisible: true),
            .more,
            .item(.bookmarks, isVisible: true),
            .item(.favourites, isVisible: true),
            .item(.local, isVisible: false),
            .item(.federated, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: nil)
        #expect(placement.tabs == [.home, .notifications, .search, .bookmarks, .favourites])
        #expect(placement.switchable.isEmpty)
        #expect(placement.location(of: .local) == .disabled)
    }

    /// 数を限らないタブバー（横幅の広いiPadのタブバー）では、境目より上の項目をすべて直接並べる。
    @Test func unlimitedTabBarPlacesEveryItemAboveBoundary() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.bookmarks, isVisible: true),
            .item(.favourites, isVisible: true),
            .more,
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: nil)
        #expect(placement.tabs == [.home, .notifications, .local, .federated, .bookmarks, .favourites])
        #expect(placement.switchable.isEmpty)
    }

    @Test func disabledItemsAreNowhere() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: false),
            .more,
            .item(.local, isVisible: true),
            .item(.federated, isVisible: false),
            .item(.search, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home])
        #expect(placement.switchable == [.local])
        #expect(placement.location(of: .notifications) == .disabled)
        #expect(placement.location(of: .federated) == .disabled)
    }

    /// 設定画面では最後の1つを無効にできないが、保存した値が壊れて全部無効になっていても、タブバーを空にしない。
    @Test func allDisabledStillShowsHome() {
        let layout = MenuLayout<TabItem>(elements: TabItem.allCases.map { .item($0, isVisible: false) } + [.more])
        let placement = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.tabs == [.home])
        #expect(placement.switchable.isEmpty)
    }

    @Test func switchSelectionKeepsPreviousWhileItStaysInSwitchTab() {
        let placement = TabPlacement(layout: MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .more,
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.notifications, isVisible: true),
            .item(.search, isVisible: false),
        ]), tabBarCapacity: TabPlacement.compactTabBarCapacity)
        #expect(placement.switchSelection(previous: nil) == .local)
        #expect(placement.switchSelection(previous: .federated) == .federated)
        // タブへ移したか無効にした項目は、切り替えタブの先頭に戻す。
        #expect(placement.switchSelection(previous: .home) == .local)
        #expect(TabPlacement(layout: TabItem.defaultLayout, tabBarCapacity: TabPlacement.compactTabBarCapacity).switchSelection(previous: .local) == nil)
    }
}

@Suite(.scratch)
@MainActor
struct TabLayoutSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = TestScratch.defaults("TabLayoutSettingsTests")
        return defaults
    }

    /// リストはアカウントごとに違うため、並びもアカウントごとに持つ。
    @Test func tabLayoutIsPerAccountAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let changed = MenuLayout<TabItem>(elements: [.item(.home, isVisible: true), .more, .item(.local, isVisible: true)])
        settings.setTabLayout(changed, for: "@alice@example.social")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.tabLayout(for: "@alice@example.social") == changed)
        #expect(relaunched.tabLayout(for: "@bob@example.social") == TabItem.defaultLayout)
    }

    /// 切り替えタブで最後に開いた項目は、起動し直しても覚えておく。アカウントごとに持つ。
    @Test func switchTabItemIsPerAccountAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setSwitchTabItem(.notifications, for: "@alice@example.social")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.switchTabItem(for: "@alice@example.social") == .notifications)
        #expect(relaunched.switchTabItem(for: "@bob@example.social") == nil)
    }

    /// 最後に見ていたタブの項目は、起動し直しても覚えておく。アカウントごとに持つ。
    @Test func shownTabItemIsPerAccountAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setShownTabItem(.local, for: "@alice@example.social")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.shownTabItem(for: "@alice@example.social") == .local)
        #expect(relaunched.shownTabItem(for: "@bob@example.social") == nil)
    }

    /// リストはIDと名前を並びに残し、同じ項目かどうかはIDだけで見る。名前に`:`が入っていても読める。
    @Test func listItemKeepsTitleButIsIdentifiedByID() {
        let item = TabItem.list(id: "12249", title: "仕事: 開発")
        #expect(item.rawValue == "list:12249:仕事: 開発")
        #expect(TabItem(rawValue: item.rawValue) == item)
        if case .list(_, let title) = TabItem(rawValue: item.rawValue) {
            #expect(title == "仕事: 開発")
        } else {
            Issue.record("リストとして読めませんでした")
        }
        #expect(item == .list(id: "12249", title: "別の名前"))
        #expect(item != .list(id: "13585", title: "仕事: 開発"))
        #expect(TabItem(rawValue: "list:") == nil)
        #expect(TabItem(.list(id: "12249")) == item)
    }

    /// 保存した並びのリストは、名前とともに読み戻せる。
    @Test func listItemSurvivesSavedTokens() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "hidden:search", "more", "item:list:5:友だち"])
        #expect(layout.tokens.contains("item:list:5:友だち"))
        #expect(TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity).switchable == [.list(id: "5", title: "友だち")])
    }

    /// まだないリストは無効にして末尾に足し、もうないリストは外し、名前が変わったリストは書き換える。表示と並びはそのまま残す。
    @Test func syncingListsAddsRemovesAndRenames() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "item:list:1:旧名", "more", "item:local", "hidden:list:2:消えるリスト"])

        let synced = layout.syncingLists([MastodonList(id: "1", title: "新名"), MastodonList(id: "3", title: "新しいリスト")])

        #expect(synced.tokens.filter { $0.contains("list:") } == ["item:list:1:新名", "hidden:list:3:新しいリスト"])
        #expect(synced.tokens.firstIndex(of: "item:list:1:新名") == 1)
        #expect(synced.tokens.last == "hidden:list:3:新しいリスト")
    }

    /// 切り替えタブで前に開いていた項目は、保存しておいた古い名前ではなく、並びの中の今の名前で返す。
    @Test func switchSelectionUsesCurrentListTitle() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:新名"])
        let restored = TabPlacement(layout: layout, tabBarCapacity: TabPlacement.compactTabBarCapacity).switchSelection(previous: .list(id: "1", title: "旧名"))
        #expect(restored?.rawValue == "list:1:新名")
    }

    /// 足りないリストだけを無効で足し、並びにあるリストは外しも書き換えもしない。
    @Test func addingMissingOnlyAppends() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:旧名", "item:list:9:ほかのウインドウで読んだリスト", "item:hashtag:Scia"])

        let added = layout.addingMissing([.list(id: "1", title: "新名"), .list(id: "2", title: "足りないリスト"), .hashtag(name: "scia"), .hashtag(name: "mastodon")])

        #expect(added.tokens.filter { $0.contains("list:") || $0.contains("hashtag:") } == [
            "item:list:1:旧名", "item:list:9:ほかのウインドウで読んだリスト", "item:hashtag:Scia", "hidden:list:2:足りないリスト", "hidden:hashtag:mastodon",
        ])
        #expect(added.addingMissing([.list(id: "2", title: "足りないリスト")]).tokens == added.tokens)
    }

    /// 名前だけが変わった並びは、項目どうしでは同じでも、保存の形では違う。設定画面は保存の形で並びの変化を見分ける。
    @Test func renamedListChangesTokensButNotItems() {
        let before = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:旧名"])
        let after = before.syncingLists([MastodonList(id: "1", title: "新名")])
        #expect(after.elements == before.elements)
        #expect(after.tokens != before.tokens)
    }

    /// ハッシュタグは、サーバーと同じ決まりでそろえた名前で同じ項目かを見る。保存した名前はそのまま読み戻す。
    @Test func hashtagItemIsIdentifiedByNormalizedName() {
        let item = TabItem.hashtag(name: "Scia")
        #expect(item.rawValue == "hashtag:Scia")
        #expect(TabItem(rawValue: "hashtag:Scia")?.rawValue == "hashtag:Scia")
        #expect(item == .hashtag(name: "scia"))
        #expect(item == .hashtag(name: "ＳＣＩＡ"))
        #expect(item != .hashtag(name: "mastodon"))
        #expect(item != .list(id: "Scia", title: ""))
        #expect(TabItem(rawValue: "hashtag:") == nil)
        #expect(TabItem(.hashtag(name: "scia")) == item)
    }

    /// フォローしているハッシュタグを並びに反映する。リストには触れない。
    @Test func syncingHashtagsAddsAndRemovesOnlyHashtags() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "item:hashtag:Scia", "more", "item:list:1:友だち", "hidden:hashtag:やめたタグ"])

        let synced = layout.syncingHashtags([Hashtag(name: "scia"), Hashtag(name: "mastodon")])

        #expect(synced.tokens.filter { $0.contains("list:") || $0.contains("hashtag:") } == ["item:hashtag:scia", "item:list:1:友だち", "hidden:hashtag:mastodon"])
        // 並びに書かなかった決まった項目は既定の位置に差し込まれるため、境目より上に残ることで、元の場所を保ったと見る。
        #expect(TabPlacement(layout: synced, tabBarCapacity: nil).tabs.contains(.hashtag(name: "scia")))
    }

    /// ユーザーのハッシュタグは、IDとハンドルと名前と付けた名前を並びに残し、同じ項目かはIDとそろえた名前で見る。付けた名前は`:`を含んでもよい。
    @Test func accountHashtagItemRoundTripsAndMatchesByIDAndNormalizedName() {
        let item = TabItem.accountHashtag(accountID: "109", acct: "bob@remote.example", name: "Scia", title: "ボブ: Scia")
        #expect(TabItem(rawValue: item.rawValue) == item)
        if case .accountHashtag(let id, let acct, let name, let title) = TabItem(rawValue: item.rawValue) {
            #expect([id, acct, name, title] == ["109", "bob@remote.example", "Scia", "ボブ: Scia"])
        } else {
            Issue.record("ユーザーのハッシュタグとして読めませんでした")
        }
        #expect(item == .accountHashtag(accountID: "109", acct: "", name: "scia"))
        #expect(item != .accountHashtag(accountID: "110", acct: "bob@remote.example", name: "Scia"))
        #expect(item != .hashtag(name: "Scia"))
    }

    /// 使う人が足したユーザーのハッシュタグは、有効にして切り替えタブの末尾に入り、外せる。同じ項目は2つ足さない。
    /// 既定の並びは5つでタブバーが埋まっているため、足すと切り替えタブの分を空け、5つ目の検索も切り替えタブに入る。
    @Test func addingAccountHashtagPutsItInSwitchTabAndRemovingDropsIt() {
        let item = TabItem.accountHashtag(accountID: "109", acct: "bob", name: "scia")
        let added = TabItem.defaultLayout.adding(item)

        #expect(TabPlacement(layout: added, tabBarCapacity: TabPlacement.compactTabBarCapacity).location(of: item) == .switchTab)
        #expect(TabPlacement(layout: added, tabBarCapacity: TabPlacement.compactTabBarCapacity).tabs == [.home, .local, .federated, .notifications])
        #expect(TabPlacement(layout: added, tabBarCapacity: TabPlacement.compactTabBarCapacity).switchable == [.search, item])
        #expect(added.adding(item).tokens == added.tokens)
        #expect(added.removing(item).tokens == TabItem.defaultLayout.tokens)
        #expect(!added.removing(item).contains(item))
    }

    /// 名前を変えた項目は、同じ場所と表示のまま置き換わる。
    @Test func replacingKeepsPositionAndVisibility() {
        let item = TabItem.accountHashtag(accountID: "109", acct: "bob", name: "scia")
        let renamed = TabItem.accountHashtag(accountID: "109", acct: "bob", name: "scia", title: "ボブ")
        let layout = TabItem.defaultLayout.adding(item).adding(.hashtag(name: "cat"))

        let replaced = layout.replacing(renamed)

        #expect(replaced.tokens == layout.tokens.map { $0 == "item:\(item.rawValue)" ? "item:\(renamed.rawValue)" : $0 })
        if case .accountHashtag(_, _, _, let title) = replaced.item(matching: item) {
            #expect(title == "ボブ")
        } else {
            Issue.record("置き換えた項目が見つかりませんでした")
        }
    }

    /// 最初の並びに戻しても、戻す前の並びにあったユーザーのハッシュタグとプロフィールは、無効にして残す。サーバーから取得して足し直せないため。
    @Test func resetKeepsUserAddedItemsDisabled() {
        let item = TabItem.accountHashtag(accountID: "109", acct: "bob", name: "scia", title: "ボブ")
        let profile = TabItem.profile(accountID: "110", acct: "carol@remote.example")
        let previous = TabItem.defaultLayout.adding(item).adding(profile).adding(.list(id: "1", title: "友だち"))

        let reset = TabItem.defaultLayout.keepingUserAddedItems(of: previous)

        #expect(reset.elements.contains(.item(item, isVisible: false)))
        #expect(reset.elements.contains(.item(profile, isVisible: false)))
        #expect(!reset.contains(.list(id: "1", title: "")))
        if case .accountHashtag(_, _, _, let title) = reset.item(matching: item) {
            #expect(title == "ボブ")
        } else {
            Issue.record("ユーザーのハッシュタグが残っていません")
        }
        #expect(previous.keepingUserAddedItems(of: previous).tokens == previous.tokens)
    }

    /// プロフィールの項目は、IDとハンドルと付けた名前を保存し、同じ項目かどうかはIDだけで見る。付けた名前は`:`を含みうる。
    @Test func profileItemRoundTripsAndMatchesByID() {
        let item = TabItem.profile(accountID: "109", acct: "bob@remote.example", title: "ボブ: 仕事")
        if case .profile(let id, let acct, let title) = TabItem(rawValue: item.rawValue) {
            #expect(id == "109")
            #expect(acct == "bob@remote.example")
            #expect(title == "ボブ: 仕事")
        } else {
            Issue.record("保存した値から読めませんでした")
        }
        #expect(item == .profile(accountID: "109", acct: "", title: ""))
        #expect(item != .profile(accountID: "110", acct: "bob@remote.example"))
        #expect(item != .accountHashtag(accountID: "109", acct: "bob@remote.example", name: "scia"))
        #expect(TabItem(rawValue: "profile:109") == nil)
        #expect(TabItem(rawValue: "profile::bob:") == nil)
    }

    /// タブの名前は、付けた名前がなければハンドルの`@`より前にする。ほかのサーバーの人と付けた名前のときは、設定の並びにハンドルを添える。
    @Test func profileItemTitleAndDetail() {
        #expect(TabItem.profile(accountID: "1", acct: "bob").title == "@bob")
        #expect(TabItem.profile(accountID: "1", acct: "bob").detail == nil)
        #expect(TabItem.profile(accountID: "1", acct: "bob@remote.example").title == "@bob")
        #expect(TabItem.profile(accountID: "1", acct: "bob@remote.example").detail == "@bob@remote.example")
        #expect(TabItem.profile(accountID: "1", acct: "bob", title: "ボブ").title == "ボブ")
        #expect(TabItem.profile(accountID: "1", acct: "bob", title: "ボブ").detail == "@bob")
    }

    @Test func renamedChangesOnlyUserAddedItems() {
        if case .profile(let id, let acct, let title) = TabItem.profile(accountID: "1", acct: "bob").renamed("ボブ") {
            #expect(id == "1")
            #expect(acct == "bob")
            #expect(title == "ボブ")
        } else {
            Issue.record("プロフィールのまま変わっていません")
        }
        if case .accountHashtag(_, _, let name, let title) = TabItem.accountHashtag(accountID: "1", acct: "bob", name: "scia").renamed("ボブ") {
            #expect(name == "scia")
            #expect(title == "ボブ")
        } else {
            Issue.record("ユーザーのハッシュタグのまま変わっていません")
        }
        #expect(TabItem.home.renamed("ボブ").rawValue == "home")
    }

    /// 操作の記録には、リストやハッシュタグの名前、ハンドル、付けた名前を残さない。IDは残す。
    @Test func logNameOmitsNamesAndHandles() {
        #expect(TabItem.home.logName == "home")
        #expect(TabItem.list(id: "7", title: "友だち").logName == "list:7")
        #expect(TabItem.hashtag(name: "cat").logName == "hashtag")
        #expect(TabItem.accountHashtag(accountID: "109", acct: "bob@remote.example", name: "scia", title: "ボブ").logName == "accountHashtag:109")
        #expect(TabItem.profile(accountID: "109", acct: "bob@remote.example", title: "ボブ").logName == "profile:109")
    }
}
