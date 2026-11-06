import Foundation
import Testing
@testable import SciaCore

struct AppDestinationTests {
    @Test func readsScreens() throws {
        let expected: [(String, AppDestination?)] = [
            ("scia://tab/home", .tab(.home)),
            ("scia://tab/scheduled", .tab(.scheduled)),
            ("scia://tab/list?id=12", .userTab(.list(id: "12"))),
            ("scia://tab/hashtag?name=scia", .userTab(.hashtag(name: "scia"))),
            ("scia://tab/profile?acct=bob%40example.com", .userTab(.profile(acct: "bob@example.com"))),
            ("scia://tab/account-hashtag?acct=bob&name=scia", .userTab(.accountHashtag(acct: "bob", name: "scia"))),
            ("scia://tab/account-hashtag?acct=bob", nil),
            ("scia://tab/unknown", nil),
            ("scia://settings", .settings(nil)),
            ("scia://settings/unknown", nil),
            ("scia://profile/@bob@example.com", .profile(acct: "bob@example.com")),
            ("scia://profile", nil),
            ("scia://my-profile", .myProfile),
            ("scia://profile-edit", .profileEdit),
            ("scia://thread?id=123", .thread(statusID: "123")),
            ("scia://thread", nil),
            ("scia://thread?id=", nil),
            ("scia://edit-history?id=123", .editHistory(statusID: "123")),
            ("scia://api-response?id=123", .apiResponse(statusID: "123")),
            ("scia://api-response", nil),
            ("scia://accounts/followers", .accounts(.followers(accountID: nil))),
            ("scia://accounts/following?id=9", .accounts(.following(accountID: "9"))),
            ("scia://accounts/favourited?id=123", .accounts(.favourited(statusID: "123"))),
            ("scia://accounts/reblogged?id=123", .accounts(.reblogged(statusID: "123"))),
            ("scia://accounts/favourited", nil),
            ("scia://hashtag?name=scia", .hashtag(name: "scia")),
            ("scia://account-hashtag?acct=bob&name=scia", .accountHashtag(acct: "bob", name: "scia")),
            ("scia://search", .search(query: nil)),
            ("scia://search?q=%E7%8C%AB%20%26%20%E7%8A%AC", .search(query: "猫 & 犬")),
            ("scia://search?q=", .search(query: nil)),
            ("scia://tab/search", .tab(.search)),
            ("scia://scheduled", .scheduled),
            ("scia://operation-status", .operationStatus),
            ("scia://notification-requests", .notificationRequests),
            ("scia://notification-request?id=7", .notificationRequest(id: "7")),
            ("scia://notification-request", nil),
            ("scia://notification-policy", .notificationPolicy),
            ("scia://announcements", .announcements),
            ("scia://in-app-browser-height", .inAppBrowserHeight(returningTo: nil)),
            ("scia://in-app-browser-height?return=interaction", .inAppBrowserHeight(returningTo: .interaction)),
            ("scia://in-app-browser-height?return=unknown", nil),
            ("scia://note?acct=bob%40example.com", .note(acct: "bob@example.com")),
            ("scia://report?acct=bob", .report(acct: "bob")),
            ("scia://compose/tools", .compose(.tools)),
            ("scia://compose/language", .compose(.language)),
            ("scia://compose/schedule", .compose(.schedule)),
            ("scia://compose/emoji", .compose(.emoji)),
            ("scia://compose/media-picker", .compose(.mediaPicker)),
            ("scia://compose/attachment", .compose(.attachment(index: 0))),
            ("scia://compose/alt-text?index=2", .compose(.altText(index: 2))),
            ("scia://compose/crop?index=1", .compose(.crop(index: 1))),
            ("scia://compose/crop?index=-1", nil),
            ("scia://unknown", nil),
        ]
        for (string, destination) in expected {
            #expect(AppDestination(try #require(URL(string: string))) == destination, "\(string)")
        }
    }

    @Test(arguments: SettingsPage.allCases)
    func readsEverySettingsPage(_ page: SettingsPage) throws {
        let url = try #require(URL(string: "scia://settings/\(page.rawValue)"))
        #expect(AppDestination(url) == .settings(page))
    }

    /// 「投稿の見た目」のどの分類の画面も、URLで開ける。分類にない名前は読まない。
    @Test(arguments: AppearanceCatalog.groups.map(\.id))
    func readsEveryAppearanceGroup(_ id: AppearanceGroup.ID) throws {
        let url = try #require(URL(string: "scia://settings/appearance/\(id)"))
        #expect(AppDestination(url) == .appearanceGroup(id))
    }

    @Test func ignoresUnknownAppearanceGroup() throws {
        #expect(AppDestination(try #require(URL(string: "scia://settings/appearance/unknown"))) == nil)
    }

    /// 「通知の見た目」のどの分類の画面も、URLで開ける。「投稿の見た目」の分類の名前は読まない。
    @Test(arguments: NotificationAppearanceCatalog.groups.map(\.id))
    func readsEveryNotificationAppearanceGroup(_ id: AppearanceGroup.ID) throws {
        let url = try #require(URL(string: "scia://settings/notification-appearance/\(id)"))
        #expect(AppDestination(url) == .notificationAppearanceGroup(id))
    }

    @Test func ignoresPostGroupAsNotificationAppearanceGroup() throws {
        #expect(AppDestination(try #require(URL(string: "scia://settings/notification-appearance/name"))) == nil)
    }

    /// 開く先の項目ごとに1つ以上。開く先を足したら、ここにも足す。
    static let samples: [AppDestination] = [.tab(.home), .tab(.scheduled)]
        + [.userTab(.list(id: "12")), .userTab(.hashtag(name: "日本語")), .userTab(.profile(acct: "bob@example.com")), .userTab(.accountHashtag(acct: "bob", name: "scia"))]
        + [.settings(nil)] + SettingsPage.allCases.map { .settings($0) } + [.appearanceGroup("name"), .notificationAppearanceGroup("header")]
        + [.profile(acct: "bob@example.com"), .profile(acct: "bob"), .myProfile, .profileEdit]
        + [.thread(statusID: "123"), .editHistory(statusID: "123"), .apiResponse(statusID: "123")]
        + [.accounts(.followers(accountID: nil)), .accounts(.followers(accountID: "9")), .accounts(.following(accountID: nil)), .accounts(.following(accountID: "9"))]
        + [.accounts(.favourited(statusID: "123")), .accounts(.reblogged(statusID: "123")), .accounts(.emojiReactioned(statusID: "123", name: "👍")), .accounts(.emojiReactioned(statusID: "123", name: "blob_cat"))]
        + [.hashtag(name: "日本語 & tag"), .accountHashtag(acct: "bob@example.com", name: "scia"), .search(query: nil), .search(query: "https://example.com/@bob/1"), .scheduled, .operationStatus]
        + [.notificationRequests, .notificationRequest(id: "7"), .notificationPolicy, .announcements, .inAppBrowserHeight(returningTo: nil), .inAppBrowserHeight(returningTo: .interaction)]
        + [.note(acct: "bob@example.com"), .report(acct: "bob+1@example.com")]
        + [.compose(.tools), .compose(.language), .compose(.schedule), .compose(.emoji), .compose(.mediaPicker)]
        + [.compose(.attachment(index: 0)), .compose(.altText(index: 2)), .compose(.crop(index: 3))]

    /// 作ったURLを読み戻すと、同じ開く先になる。URLの形を書いても、読み取りを書き忘れていればURLを作れずに落ちる。
    @Test(arguments: samples)
    func readsBackItsOwnURL(_ destination: AppDestination) throws {
        let url = try #require(destination.url(scheme: "scia"))
        #expect(url.scheme == "scia")
        #expect(AppDestination(url) == destination, "\(url.absoluteString)")
    }

    /// 見本が、開く先のすべての項目を含む。開く先を足すと`kind(of:)`がビルドできなくなり、足した種類の見本がなければこのテストが落ちる。
    @Test func samplesCoverEveryKind() {
        #expect(Set(Self.samples.map(Self.kind(of:))) == Set(Kind.allCases))
    }

    @Test(arguments: [
        AppDestination.hashtag(name: ""),
        .thread(statusID: ""),
        .search(query: ""),
        .profile(acct: ""),
        .accounts(.followers(accountID: "")),
        .compose(.crop(index: -1)),
        .userTab(.accountHashtag(acct: "bob", name: "")),
    ])
    func refusesValuesThatDoNotReadBack(_ destination: AppDestination) {
        #expect(destination.url(scheme: "scia") == nil)
    }

    enum Kind: CaseIterable {
        case tab, userTabList, userTabHashtag, userTabProfile, userTabAccountHashtag, settings, appearanceGroup, notificationAppearanceGroup, profile, myProfile, profileEdit
        case thread, editHistory, apiResponse, followers, following, favourited, reblogged, emojiReactioned, hashtag, accountHashtag, search, scheduled, operationStatus
        case notificationRequests, notificationRequest, notificationPolicy, announcements, inAppBrowserHeight
        case note, report, composeTools, composeLanguage, composeSchedule, composeEmoji, composeMediaPicker, composeAttachment, composeAltText, composeCrop
    }

    static func kind(of destination: AppDestination) -> Kind {
        switch destination {
        case .tab: .tab
        case .userTab(.list): .userTabList
        case .userTab(.hashtag): .userTabHashtag
        case .userTab(.profile): .userTabProfile
        case .userTab(.accountHashtag): .userTabAccountHashtag
        case .settings: .settings
        case .appearanceGroup: .appearanceGroup
        case .notificationAppearanceGroup: .notificationAppearanceGroup
        case .profile: .profile
        case .myProfile: .myProfile
        case .profileEdit: .profileEdit
        case .thread: .thread
        case .editHistory: .editHistory
        case .apiResponse: .apiResponse
        case .accounts(.followers): .followers
        case .accounts(.following): .following
        case .accounts(.favourited): .favourited
        case .accounts(.reblogged): .reblogged
        case .accounts(.emojiReactioned): .emojiReactioned
        case .hashtag: .hashtag
        case .accountHashtag: .accountHashtag
        case .search: .search
        case .scheduled: .scheduled
        case .operationStatus: .operationStatus
        case .notificationRequests: .notificationRequests
        case .notificationRequest: .notificationRequest
        case .notificationPolicy: .notificationPolicy
        case .announcements: .announcements
        case .inAppBrowserHeight: .inAppBrowserHeight
        case .note: .note
        case .report: .report
        case .compose(.tools): .composeTools
        case .compose(.language): .composeLanguage
        case .compose(.schedule): .composeSchedule
        case .compose(.emoji): .composeEmoji
        case .compose(.mediaPicker): .composeMediaPicker
        case .compose(.attachment): .composeAttachment
        case .compose(.altText): .composeAltText
        case .compose(.crop): .composeCrop
        }
    }

    @Test func pushesStorageBeforeMediaCache() {
        #expect(SettingsPage.viewedMediaCache.path == [.storage, .viewedMediaCache])
        #expect(SettingsPage.licenses.path == [.about, .licenses])
        #expect(SettingsPage.acknowledgments.path == [.about, .acknowledgments])
    }

    /// 分類の中の画面は、分類の画面を挟んで開く。対象のメニューは、その対象の画面も挟む。戻ると、挟んだ画面に1つずつ戻る。
    @Test func pushesCategoryBeforeItsPages() {
        #expect(SettingsPage.appearance.path == [.display, .appearance])
        #expect(SettingsPage.linkLoading.path == [.display, .linkLoading])
        #expect(SettingsPage.statusMenu.path == [.interaction, .statusActions, .statusMenu])
        #expect(SettingsPage.mediaMenu.path == [.interaction, .mediaActions, .mediaMenu])
        #expect(SettingsPage.profileTextMenu.path == [.interaction, .profileTextMenu])
        #expect(SettingsPage.mediaActions.path == [.interaction, .mediaActions])
        #expect(SettingsPage.composeTools.path == [.compose, .composeTools])
        #expect(SettingsPage.tabs.path == [.tabs])
        #expect(SettingsPage.appIcon.path == [.appIcon])
        #expect(SettingsPage.connection.path == [.about, .connection])
    }

    /// ログには、誰の何を開いたかが分かるハンドルやIDを書かない。
    @Test func logsWithoutIdentifiers() {
        #expect(!AppDestination.note(acct: "bob@example.com").logDescription.contains("bob"))
        #expect(!AppDestination.thread(statusID: "123").logDescription.contains("123"))
    }

    /// タブを見せる行き先は、上に重ねた画面を閉じてから開く。重ねたままでは見えず、積むのもやめるため。
    /// 手前に重ねる行き先は、下の画面を残して重ねる。ビューアのメニューから開いた設定を閉じると、ビューアに戻るため。
    @Test func tellsWhichDestinationsShowTabs() {
        #expect(AppDestination.tab(.home).showsTab)
        #expect(AppDestination.userTab(.list(id: "1")).showsTab)
        #expect(AppDestination.profile(acct: "bob").showsTab)
        #expect(AppDestination.myProfile.showsTab)
        #expect(AppDestination.thread(statusID: "1").showsTab)
        #expect(AppDestination.editHistory(statusID: "1").showsTab)
        #expect(AppDestination.apiResponse(statusID: "1").showsTab)
        #expect(AppDestination.accounts(.followers(accountID: nil)).showsTab)
        #expect(AppDestination.hashtag(name: "a").showsTab)
        #expect(AppDestination.accountHashtag(acct: "bob", name: "a").showsTab)
        #expect(AppDestination.search(query: nil).showsTab)
        #expect(AppDestination.scheduled.showsTab)
        #expect(AppDestination.notificationRequests.showsTab)
        #expect(AppDestination.notificationRequest(id: "1").showsTab)

        #expect(!AppDestination.settings(nil).showsTab)
        #expect(!AppDestination.appearanceGroup("row").showsTab)
        #expect(!AppDestination.notificationAppearanceGroup("header").showsTab)
        #expect(!AppDestination.profileEdit.showsTab)
        #expect(!AppDestination.operationStatus.showsTab)
        #expect(!AppDestination.notificationPolicy.showsTab)
        #expect(!AppDestination.announcements.showsTab)
        #expect(!AppDestination.inAppBrowserHeight(returningTo: nil).showsTab)
        #expect(!AppDestination.note(acct: "bob").showsTab)
        #expect(!AppDestination.report(acct: "bob").showsTab)
        #expect(!AppDestination.compose(.tools).showsTab)
    }

    @Test func matchesUserTabsLikeTheLayout() throws {
        let credential = Credential(instance: try #require(URL(string: "https://example.social")), accessToken: "", clientID: "", clientSecret: "", accountID: "1", username: "me")
        #expect(AppDestination.UserTab.profile(acct: "bob@example.social").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(AppDestination.UserTab.profile(acct: "@Bob").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(!AppDestination.UserTab.profile(acct: "bob@other.example").matches(.profile(accountID: "2", acct: "bob"), credential: credential))
        #expect(AppDestination.UserTab.hashtag(name: "ＳＣＩＡ").matches(.hashtag(name: "scia"), credential: credential))
        #expect(AppDestination.UserTab.accountHashtag(acct: "bob@example.social", name: "Café").matches(.accountHashtag(accountID: "2", acct: "bob", name: "cafe"), credential: credential))
        #expect(AppDestination.UserTab.list(id: "3").matches(.list(id: "3", title: "a"), credential: credential))
        #expect(!AppDestination.UserTab.list(id: "3").matches(.hashtag(name: "3"), credential: credential))
    }
}
