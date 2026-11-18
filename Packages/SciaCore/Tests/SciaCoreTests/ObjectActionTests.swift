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
        #expect(settings.quotedStatusActions == ObjectActions(tap: .item(.openThread), longPress: .menu))
        #expect(settings.notificationActions == ObjectActions(tap: .item(.openThread), longPress: .menu))
        #expect(settings.userActions == ObjectActions(tap: .item(.profile), longPress: .menu))
        #expect(settings.linkActions == ObjectActions(tap: .item(.openInBrowser), longPress: .menu))
        #expect(settings.externalPostActions == ObjectActions(tap: .item(.openInBrowser), longPress: .menu))
        #expect(settings.hashtagActions == ObjectActions(tap: .item(.timeline), longPress: .menu))
        #expect(settings.mediaActions == ObjectActions(tap: .item(.open), longPress: .menu))
        #expect(settings.reactionActions == ObjectActions(tap: .item(.toggle), longPress: .menu))
    }

    @Test func persistsActions() {
        let defaults = TestScratch.defaults("ObjectActionTests")
        let settings = AppSettings(defaults: defaults)
        settings.statusActions = ObjectActions(tap: .menu, longPress: .item(.favourite))
        settings.userActions = ObjectActions(tap: .item(.mention), longPress: .item(.profile))
        settings.externalPostActions = ObjectActions(tap: .item(.openInBrowser), longPress: .item(.systemTranslate))
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.statusActions == ObjectActions(tap: .menu, longPress: .item(.favourite)))
        #expect(relaunched.userActions == ObjectActions(tap: .item(.mention), longPress: .item(.profile)))
        #expect(relaunched.externalPostActions == ObjectActions(tap: .item(.openInBrowser), longPress: .item(.systemTranslate)))
        // リンクとほかのサービスの投稿は、どちらもブラウザで開くが、別の設定にする。
        #expect(relaunched.linkActions == .standard)
        // 投稿と引用の投稿と通知は同じ項目から選ぶが、別の設定にする。
        #expect(relaunched.quotedStatusActions == .standard)
        #expect(relaunched.notificationActions == .standard)
    }

    /// なくなった項目や知らない形は、その操作だけ既定に戻す。
    @Test func unknownTokensFallBackToDefaultPerTrigger() {
        let settings = AppSettings(defaults: TestScratch.defaults("ObjectActionTests"))
        settings.store.updateLibrary { library throws(PresetError) in
            try library.setValue(.text("item:removedItem"), forKey: "objectActions.status.tap", for: .app)
            try library.setValue(.text("item:bookmark"), forKey: "objectActions.status.longPress", for: .app)
            try library.setValue(.text("menu"), forKey: "objectActions.link.tap", for: .app)
            try library.setValue(.text("unknown"), forKey: "objectActions.link.longPress", for: .app)
        }
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
}
