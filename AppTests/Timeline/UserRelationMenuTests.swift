import SciaCore
import Testing
import UIKit
@testable import Scia

/// ユーザーのメニューの関係の項目が、関係に合わせて中身を変えることを確かめる。
@MainActor
struct UserRelationMenuTests {
    /// 項目の名前。押せないものは`(押せない)`、チェックの付いたものは`✓`、取り消せない操作は`!`を付け、サブメニューは`名前[中身]`で表す。
    private func describe(_ item: UserMenuItem, _ relationship: Relationship) -> [String] {
        UserMenuActions.relationElements(item, relationship: relationship) { _ in }.map(describe)
    }

    private func describe(_ element: UIMenuElement) -> String {
        if let menu = element as? UIMenu {
            return "\(menu.title)[\(menu.children.map(describe).joined(separator: ","))]"
        }
        guard let action = element as? UIAction else { return element.title }
        return action.title + (action.state == .on ? "✓" : "") + (action.attributes.contains(.destructive) ? "!" : "")
    }

    /// フォローは、していなければフォロー、していれば外す、リクエスト中なら取り消す。ブロックしているか、されていれば出さない。
    @Test func followItemFollowsRelationship() {
        #expect(describe(.follow, Relationship(id: "2")) == ["フォロー"])
        #expect(describe(.follow, Relationship(id: "2", following: true)) == ["フォローを外す"])
        #expect(describe(.follow, Relationship(id: "2", requested: true)) == ["フォローのリクエストを取り消す"])
        #expect(describe(.follow, Relationship(id: "2", blocking: true)).isEmpty)
        #expect(describe(.follow, Relationship(id: "2", blockedBy: true)).isEmpty)
    }

    /// フォローの設定は、フォロー中かリクエスト中の相手にだけ、今の設定をチェックで示して出す。
    @Test func followSettingsShowCurrentStateOnlyWhenFollowing() {
        #expect(describe(.showReblogs, Relationship(id: "2")).isEmpty)
        #expect(describe(.notify, Relationship(id: "2")).isEmpty)
        #expect(describe(.showReblogs, Relationship(id: "2", following: true, showingReblogs: true)) == ["ブーストを表示✓"])
        #expect(describe(.showReblogs, Relationship(id: "2", following: true, showingReblogs: false)) == ["ブーストを表示"])
        #expect(describe(.notify, Relationship(id: "2", notifying: true, requested: true)) == ["投稿を通知✓"])
    }

    /// ミュートは期間を選ぶサブメニューにし、ミュート中なら解除を出す。ブロックは取り消せない操作として示し、ブロック中なら解除を出す。
    @Test func muteAndBlockItems() {
        #expect(describe(.mute, Relationship(id: "2")) == ["ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]"])
        #expect(describe(.mute, Relationship(id: "2", muting: true)) == ["ミュートを解除"])
        #expect(describe(.block, Relationship(id: "2")) == ["ブロック!"])
        #expect(describe(.block, Relationship(id: "2", blocking: true)) == ["ブロックを解除"])
    }
}
