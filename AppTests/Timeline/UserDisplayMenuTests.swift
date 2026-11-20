import Foundation
import SciaCore
import SciaTesting
import Testing
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct UserDisplayMenuTests {
    @Test func customizationDispatchesTheSelectedMentionTarget() throws {
        let url = try #require(URL(string: "https://remote.example/@alice"))
        var received: UserMenuTarget?
        let actions = UserMenuActions(
            mention: { _ in }, copy: { _, _, _ in }, localServer: "example.social",
            resolveTarget: { _ in throw CancellationError() }, loadRelation: { _, _ in nil },
            knownRelation: { _ in nil }, reloadRelations: { _ in }, changeRelation: { _, _ in },
            editNote: { _ in }, report: { _, _, _ in }, addToList: { _ in },
            editDisplay: { received = $0 }, accounts: AccountCache { _ in [] }
        )
        let handlers = URLMenuHandlers(linkBrowser: .inApp, copy: { _ in }, share: { _ in }, open: { _, _ in }, openSettings: { _ in Issue.record("メニューの並びの設定を開いています") })
        let menu = UserMenu(subject: UserMenuSubject(mentionLink: url, acct: "alice"), actions: actions, handlers: handlers, host: nil)
        let root = try #require(menu.tree.menu(groups: .single(.editDisplay), avatar: nil))
        let command = try #require(root.flattenedChildren.compactMap(\.command).first)
        menu.perform(command, openProfile: { Issue.record("プロフィールを開いています") })
        guard case .profileURL(let receivedURL, let acct) = received else {
            Issue.record("選択したメンションの対象が渡っていません")
            return
        }
        #expect(receivedURL == url)
        #expect(acct == "alice")
    }
}
