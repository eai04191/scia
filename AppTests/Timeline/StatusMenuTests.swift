import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct StatusMenuTests {
    private func linkActions(of status: Status) throws -> [UIAction] {
        let viewController = TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline)
        let menu = viewController.statusMenu(for: status, id: .status(status.id))
        let links = try #require(menu.children.compactMap { $0 as? UIMenu }.first { $0.options.contains(.displayInline) })
        return links.children.compactMap { $0 as? UIAction }
    }

    private func status(url: URL?, reblog: Status? = nil) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: url, reblog: reblog)
    }

    @Test func linkActionsAreListedInOrder() throws {
        let actions = try linkActions(of: status(url: URL(string: "https://example.social/@alice/100")))

        #expect(actions.map(\.title) == ["リンクをコピー", "共有", "ブラウザで開く"])
        #expect(actions.allSatisfy { !$0.attributes.contains(.disabled) })
    }

    /// ブーストは元の投稿のページを指す。ブーストの側のurlがなくても、元の投稿にあれば押せる。
    @Test func reblogUsesOriginalStatusURL() throws {
        let original = try status(url: URL(string: "https://remote.example/@bob/1"))
        let actions = try linkActions(of: status(url: nil, reblog: original))

        #expect(actions.allSatisfy { !$0.attributes.contains(.disabled) })
    }

    /// urlはAPIでnullを取りうる。ないときは押せないまま並べ、uriで代わりにしない。
    @Test func linkActionsAreDisabledWithoutURL() throws {
        let actions = try linkActions(of: status(url: nil))

        #expect(actions.count == 3)
        #expect(actions.allSatisfy { $0.attributes.contains(.disabled) })
    }
}
