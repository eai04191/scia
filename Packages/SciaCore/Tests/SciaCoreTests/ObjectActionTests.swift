import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct ObjectActionTests {
    /// 既定は今の挙動にする。タップは各対象の主な操作、長押しはメニュー。
    @Test func defaultsKeepCurrentBehavior() {
        let settings = AppSettings(defaults: TestScratch.defaults("ObjectActionTests"))
        #expect(settings.statusActions == ObjectActions(tap: .item(.openThread), longPress: .menu))
        #expect(settings.notificationActions == ObjectActions(tap: .item(.openThread), longPress: .menu))
        #expect(settings.userActions == ObjectActions(tap: .item(.profile), longPress: .menu))
        #expect(settings.linkActions == ObjectActions(tap: .item(.openInBrowser), longPress: .menu))
        #expect(settings.hashtagActions == ObjectActions(tap: .item(.timeline), longPress: .menu))
        #expect(settings.mediaActions == ObjectActions(tap: .item(.open), longPress: .menu))
    }

    @Test func persistsActions() {
        let defaults = TestScratch.defaults("ObjectActionTests")
        let settings = AppSettings(defaults: defaults)
        settings.statusActions = ObjectActions(tap: .menu, longPress: .item(.favourite))
        settings.userActions = ObjectActions(tap: .item(.mention), longPress: .item(.profile))
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.statusActions == ObjectActions(tap: .menu, longPress: .item(.favourite)))
        #expect(relaunched.userActions == ObjectActions(tap: .item(.mention), longPress: .item(.profile)))
        // 投稿と通知は同じ項目から選ぶが、別の設定にする。
        #expect(relaunched.notificationActions == .standard)
    }

    /// なくなった項目や知らない形は、その操作だけ既定に戻す。
    @Test func unknownTokensFallBackToDefaultPerTrigger() {
        let defaults = TestScratch.defaults("ObjectActionTests")
        defaults.set(["item:removedItem", "item:bookmark"], forKey: "settings.objectActions.status")
        defaults.set(["menu"], forKey: "settings.objectActions.link")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.statusActions == ObjectActions(tap: .item(.openThread), longPress: .item(.bookmark)))
        #expect(settings.linkActions == ObjectActions(tap: .menu, longPress: .menu))
    }

    @Test func performsPrimary() {
        #expect(ObjectActions<StatusMenuItem>.standard.performsPrimary(.tap))
        #expect(!ObjectActions<StatusMenuItem>.standard.performsPrimary(.longPress))
        #expect(!ObjectActions<MediaMenuItem>(tap: .menu, longPress: .item(.share)).performsPrimary(.tap))
    }

    @Test func tokens() {
        #expect(ObjectAction<StatusMenuItem>.menu.token == "menu")
        #expect(ObjectAction<StatusMenuItem>.item(.reply).token == "item:reply")
        #expect(ObjectAction<StatusMenuItem>(token: "item:reply") == .item(.reply))
        #expect(ObjectAction<StatusMenuItem>(token: "hidden:reply") == nil)
        #expect(ObjectAction<StatusMenuItem>(token: "item:profile") == nil)
    }

    /// タップと長押しのどちらでもメニューを開かない組み合わせも許し、それが分かるようにする。
    @Test func opensMenu() {
        #expect(ObjectActions<StatusMenuItem>.standard.opensMenu)
        #expect(ObjectActions<StatusMenuItem>(tap: .menu, longPress: .item(.openThread)).opensMenu)
        #expect(!ObjectActions<StatusMenuItem>(tap: .item(.openThread), longPress: .item(.favourite)).opensMenu)
    }

    /// 「スレッドを開く」は、既定ではタップで開けるため、メニューでは隠す。
    @Test func openThreadIsHiddenInMenuByDefault() {
        let element = StatusMenuItem.defaultLayout.elements.first { if case .item(.openThread, _) = $0 { true } else { false } }
        #expect(element == .item(.openThread, isVisible: false))
        #expect(!StatusMenuItem.defaultLayout.groups.main.flatMap(\.items).contains(.openThread))
    }
}
