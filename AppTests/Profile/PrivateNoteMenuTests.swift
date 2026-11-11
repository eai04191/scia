import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 自分にしか見えないメモの欄を長押ししたときのメニュー。決まりはdocs/menus.mdの「プロフィールの文章のメニュー」にある。
@Suite(.scratch, .failureState)
@MainActor
struct PrivateNoteMenuTests {
    private func makeViewController() -> TimelineViewController {
        let settings = AppSettings(defaults: TestScratch.defaults("PrivateNoteMenuTests"))
        settings.useMenuFixtures()
        return TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
    }

    /// まとまりごとの項目の名前。
    private func outline(_ menu: UIMenu) -> [[String]] {
        menu.children.map { element in
            guard let group = element as? UIMenu, group.options.contains(.displayInline) else { return [element.title] }
            return group.children.map(\.title)
        }
    }

    /// 先頭に「メモを編集」を置き、その下に「テキストをコピー」を並べる。自分で書いた文章なので翻訳は出さず、ラベルのコピーとカスタム絵文字も出ない。
    /// プロフィールの文章のメニューと並びを共有するので、「その他」にそのカスタマイズが入る。
    @Test func editComesFirstFollowedByTextItems() {
        let menu = makeViewController().privateNoteMenu(for: "前に会った :blobcat:") {}

        #expect(outline(menu) == [["メモを編集"], ["テキストをコピー"], ["その他"]])
    }

    @Test func editOpensTheNoteSheet() throws {
        var edits = 0
        let menu = makeViewController().privateNoteMenu(for: "前に会った") { edits += 1 }

        let edit = try #require((menu.children.first as? UIMenu)?.children.first as? UIAction)
        edit.performWithSender(nil, target: nil)
        #expect(edits == 1)
    }
}
