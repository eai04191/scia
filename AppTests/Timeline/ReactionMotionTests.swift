import Foundation
import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 絵文字のリアクションが付いた、なくなった、数が変わったときの一覧の動き。決まりはdocs/emoji-reaction.mdの「動き」にある。
@MainActor
@Suite(.scratch)
struct ReactionMotionTests {
    private let thumbsUp = ReactionEmoji(name: "👍")
    private let party = ReactionEmoji(name: "🎉")

    private func harness(reactions: [EmojiReaction] = [], showsAddButton: Bool = false) throws -> (harness: TimelineHarness, statuses: [Status], id: TimelineViewController.ItemID) {
        let harness = try TimelineHarness { timeline in
            timeline.supportsEmojiReactions = true
            if showsAddButton {
                timeline.onAddEmojiReaction = { _ in }
            }
        }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        statuses[10] = Self.replacing(statuses[10], reactions: reactions)
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(statuses[10].id)
        try harness.scroll(to: id, at: .centeredVertically)
        return (harness, statuses, id)
    }

    private static func replacing(_ status: Status, reactions: [EmojiReaction]) -> Status {
        Status(id: status.id, createdAt: status.createdAt, account: status.account, content: status.content, spoilerText: "", url: nil, emojiReactions: reactions)
    }

    private func hasRowShift(_ view: UIView) -> Bool {
        view.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true
    }

    private func reactionButtons(in cell: UICollectionViewCell) -> [ReactionChipButton] {
        func collect(_ view: UIView) -> [ReactionChipButton] {
            (view as? ReactionChipButton).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return collect(cell)
    }

    /// リアクションのない見えている投稿に付いたら、行のセルを入れ替えずに伸ばし、下の行を元の位置から動かす。ボタンはその場で浮かび上がる。
    @Test func firstReactionGrowsRowAndShiftsRowsBelow() throws {
        var (harness, statuses, id) = try harness()
        defer { harness.tearDown() }
        let cell = try #require(harness.visibleCell(of: id))
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        let above = TimelineViewController.ItemID.status(statuses[9].id)
        let height = cell.frame.height

        statuses[10] = statuses[10].settingEmojiReaction(thumbsUp, true)
        harness.setStatuses(statuses)

        #expect(harness.visibleCell(of: id) === cell, "行のセルを入れ替えました")
        #expect(cell.frame.height > height)
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "下の行を動かしていません")
        #expect(try !hasRowShift(#require(harness.visibleCell(of: above))), "上の行を動かしました")
        let buttons = reactionButtons(in: cell).filter { $0.superview?.isHidden == false }
        #expect(!buttons.isEmpty)
        #expect(buttons.allSatisfy { $0.layer.animationKeys()?.isEmpty == false }, "ボタンを浮かび上がらせていません")
    }

    /// すべてなくなったら、行を縮め、下の行を元の位置から動かして覆う。
    @Test func lastReactionRemovedShrinksRowAndShiftsRowsBelow() throws {
        var (harness, statuses, id) = try harness(reactions: [EmojiReaction(emoji: thumbsUp, count: 1, me: false)])
        defer { harness.tearDown() }
        let cell = try #require(harness.visibleCell(of: id))
        let below = TimelineViewController.ItemID.status(statuses[11].id)
        let height = cell.frame.height

        statuses[10] = Self.replacing(statuses[10], reactions: [])
        harness.setStatuses(statuses)

        #expect(harness.visibleCell(of: id) === cell, "行のセルを入れ替えました")
        #expect(cell.frame.height < height)
        #expect(try hasRowShift(#require(harness.visibleCell(of: below))), "下の行を動かしていません")
    }

    /// 数だけが変わったら、ボタンを作り替えず、数のラベルを入れ替える動きを付ける。絵文字のラベルは動かさない。
    @Test func countChangeRollsOnlyTheNumber() throws {
        var (harness, statuses, id) = try harness(reactions: [EmojiReaction(emoji: thumbsUp, count: 1, me: false), EmojiReaction(emoji: party, count: 2, me: false)])
        defer { harness.tearDown() }
        let cell = try #require(harness.visibleCell(of: id))
        let button = try #require(reactionButtons(in: cell).first { $0.accessibilityLabel == "👍 1件" })

        statuses[10] = Self.replacing(statuses[10], reactions: [EmojiReaction(emoji: thumbsUp, count: 2, me: false), EmojiReaction(emoji: party, count: 2, me: false)])
        harness.setStatuses(statuses)

        #expect(button.accessibilityLabel == "👍 2件", "ボタンを作り替えました")
        #expect(button.count == 2)
        #expect(button.lastCountTransition != nil, "数を入れ替える動きを付けていません")
        #expect(button.label.layer.animationKeys()?.contains("transform") != true, "絵文字を動かしました")
        let other = try #require(reactionButtons(in: cell).first { $0.accessibilityLabel == "🎉 2件" })
        #expect(other.lastCountTransition == nil, "変わっていない数を動かしました")
    }

    /// 使い回したセルで別の投稿に替わったときは、リアクションを動かさない。
    @Test func reusedCellDoesNotAnimateReactions() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        window.addSubview(view)
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 100, width: 328, height: 400)
        let reaction = ReactionChipsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: 1, isMine: false, spokenName: "👍")
        var content = PostBodyContent(text: NSAttributedString(string: "本文"), mediaSpacing: 8)
        content.statusID = "1"
        content.reactions = [reaction]
        content.reactionsTransitionDuration = 0.35
        view.apply(content)
        view.layoutIfNeeded()

        content.statusID = "2"
        content.reactions = [ReactionChipsView.Reaction(name: "🎉", emoji: NSAttributedString(string: "🎉"), count: 3, isMine: false, spokenName: "🎉")]
        view.apply(content)
        view.layoutIfNeeded()

        let buttons = try #require(view.reactions).subviews.compactMap { $0 as? ReactionChipButton }
        #expect(!buttons.isEmpty)
        #expect(buttons.allSatisfy { $0.layer.animationKeys() == nil && $0.lastCountTransition == nil }, "別の投稿の描き直しで動かしました")
    }

    /// すでにリアクションのある列に付いたら、新しいボタンは、そこにいた「＋」が動いて場所を空けてから浮かび上がる。
    /// 同時に始めると、動き出したばかりの「＋」に、浮かび上がり始めたボタンが重なって見えるため。
    @Test func addedReactionWaitsForAddButtonToMove() throws {
        var (harness, statuses, id) = try harness(reactions: [EmojiReaction(emoji: thumbsUp, count: 1, me: false)], showsAddButton: true)
        defer { harness.tearDown() }
        let cell = try #require(harness.visibleCell(of: id))

        statuses[10] = Self.replacing(statuses[10], reactions: [EmojiReaction(emoji: thumbsUp, count: 1, me: false), EmojiReaction(emoji: party, count: 1, me: false)])
        harness.setStatuses(statuses)

        let added = try #require(reactionButtons(in: cell).first { $0.accessibilityLabel == "🎉 1件" })
        // UIKitは、遅らせる長さを、送る前の動きの`beginTime`に相対の値で入れる。
        let appear = try #require(added.layer.animation(forKey: "opacity"), "浮かび上がらせていません")
        #expect(appear.beginTime > 0, "「＋」が場所を空ける前に浮かび上がらせました")
        #expect(appear.fillMode == .backwards || appear.fillMode == .both, "待っている間に見えています")
        let plus = try #require(reactionButtons(in: cell).first { $0.accessibilityLabel != "🎉 1件" && $0.accessibilityLabel != "👍 1件" })
        let move = try #require(plus.layer.animation(forKey: "position"), "「＋」を動かしていません")
        #expect(move.beginTime == 0, "「＋」を待たせました")
    }

    /// 消えている途中に同じ絵文字がまた付いたら、新しいボタンを作らず、消えかけのボタンを戻す。同じリアクションが2か所に見えないため。
    @Test func reAddedWhileLeavingRevivesSameButton() throws {
        var (harness, statuses, id) = try harness(reactions: [EmojiReaction(emoji: thumbsUp, count: 1, me: false), EmojiReaction(emoji: party, count: 1, me: false)])
        defer { harness.tearDown() }
        let cell = try #require(harness.visibleCell(of: id))
        let leaving = try #require(reactionButtons(in: cell).first { $0.accessibilityLabel == "👍 1件" })

        statuses[10] = Self.replacing(statuses[10], reactions: [EmojiReaction(emoji: party, count: 1, me: false)])
        harness.setStatuses(statuses)
        statuses[10] = Self.replacing(statuses[10], reactions: [EmojiReaction(emoji: thumbsUp, count: 2, me: false), EmojiReaction(emoji: party, count: 1, me: false)])
        harness.setStatuses(statuses)

        let thumbs = reactionButtons(in: cell).filter { $0.label.attributedText?.string == "👍" }
        #expect(thumbs.count == 1, "同じリアクションのボタンが2つあります")
        #expect(thumbs.first === leaving, "消えかけのボタンを戻していません")
        #expect(leaving.isUserInteractionEnabled)
    }

    /// 動きの途中で別の投稿に使い回したら、前の投稿の動きと、消えかけの列の像を残さない。
    @Test func reuseCancelsRunningTransitions() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        window.addSubview(view)
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 100, width: 328, height: 400)
        func reaction(_ count: Int) -> ReactionChipsView.Reaction {
            ReactionChipsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: count, isMine: false, spokenName: "👍")
        }
        var content = PostBodyContent(text: NSAttributedString(string: "本文"), mediaSpacing: 8)
        content.statusID = "1"
        content.reactions = [reaction(1)]
        content.reactionsTransitionDuration = 0.35
        view.apply(content)
        view.layoutIfNeeded()
        content.reactions = [reaction(2)]
        view.apply(content)
        view.layoutIfNeeded()
        let button = try #require(view.reactions?.subviews.compactMap { $0 as? ReactionChipButton }.first)
        #expect(button.lastCountTransition != nil)

        content.statusID = "2"
        content.reactions = [reaction(5)]
        view.apply(content)
        view.layoutIfNeeded()

        #expect(button.lastCountTransition == nil, "前の投稿の数の入れ替わりが残っています")
        #expect(button.countGeneration > 0, "SwiftUIの表示を作り直していません。同じ値を入れ直すだけでは、続いている入れ替わりは止まりません")
        #expect(button.count == 5)
    }

    /// 狭い列で桁の多い数を出しても、数をボタンの中に収める。
    @Test func longCountStaysInsideButton() {
        let view = ReactionChipsView(frame: CGRect(x: 0, y: 0, width: 60, height: 100))
        view.apply([ReactionChipsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: 123_456_789, isMine: false, spokenName: "👍")])
        view.layoutIfNeeded()
        let button = view.subviews.compactMap { $0 as? ReactionChipButton }.first { $0.count != nil }
        #expect(button.map { $0.bounds.width <= 60 } == true)
        #expect(button.map { $0.countFrame.maxX <= $0.bounds.width + 0.5 } == true, "数がボタンの右端からはみ出しています")
    }

    /// 数を出したあとに列が狭まったら、入れ替わっていない数の枠を今の幅に収める。
    @Test func countFrameShrinksWithColumn() {
        let view = ReactionChipsView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        let reaction = ReactionChipsView.Reaction(name: "👍", emoji: NSAttributedString(string: "👍"), count: 123_456_789, isMine: false, spokenName: "👍")
        view.apply([reaction])
        view.layoutIfNeeded()
        view.frame.size.width = 60
        view.layoutIfNeeded()
        let button = view.subviews.compactMap { $0 as? ReactionChipButton }.first { $0.count != nil }
        #expect(button.map { $0.countFrame.maxX <= $0.bounds.width + 0.5 } == true, "前の広い枠のまま、数がボタンからはみ出しています")
    }
}
