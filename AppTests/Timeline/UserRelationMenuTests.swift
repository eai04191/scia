import SciaCore
import Testing
import UIKit
@testable import Scia

/// ユーザーのメニューの関係の項目が、関係に合わせて中身を変えることを確かめる。
@MainActor
struct UserRelationMenuTests {
    /// 項目の名前。押せないものは`(押せない)`、チェックの付いたものは`✓`、取り消せない操作は`!`を付け、サブメニューは`名前[中身]`で表す。
    private func describe(_ item: UserMenuItem, _ relationship: Relationship) -> [String] {
        UserMenuActions.relationElements(item, relationship: relationship, perform: { _ in }, report: {}).map(describe)
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

    /// 通報は関係によらず出す。
    @Test func reportItemIsAlwaysShown() {
        #expect(describe(.report, Relationship(id: "2")) == ["通報"])
        #expect(describe(.report, Relationship(id: "2", blocking: true)) == ["通報"])
    }

    /// 相手を探すのは、関係を読むのとは別に待てる。通報は探すのだけを待つので、関係を読めなくても出せる。
    /// 同じメニューの項目で分け合い、相手を探すのも関係を読むのも1度だけにする。
    @Test func identityIsSharedAndDoesNotWaitForRelation() async throws {
        let counts = LoadCounter()
        let load = UserRelationLoad {
            counts.resolves += 1
            return UserIdentity(id: "2", acct: "alice@remote.example")
        } load: { _ in
            counts.loads += 1
            throw URLError(.notConnectedToInternet)
        }

        #expect(try await load.identity.id == "2")
        #expect(counts.loads == 0)
        await #expect(throws: URLError.self) { try await load.value }
        await #expect(throws: URLError.self) { try await load.value }
        #expect(try await load.identity.acct == "alice@remote.example")
        #expect(counts.resolves == 1)
        #expect(counts.loads == 1)
    }

    @MainActor
    private final class LoadCounter {
        var resolves = 0
        var loads = 0
    }

    /// 関係を読めなかった知らせは、最初に出る、関係で中身が変わる項目の場所に出す。
    /// 相手を探せなかった知らせは、最初に出る、相手を探すのを待つ項目の場所に出す。通報は相手のIDが分かっていれば待たないので、探すときだけその場所になる。
    /// 通報を関係の項目より前に並べても、関係を読めなかった知らせは関係の項目の場所に出る。
    @Test func failureIsShownAtFirstItemThatWaitsForIt() {
        let reportOnly = MenuLayout<UserMenuItem>(elements: UserMenuItem.allCases.map { .item($0, isVisible: $0 == .profile || $0 == .report) } + [.more]).groups
        let reportFirst = MenuLayout<UserMenuItem>(elements: [.item(.report, isVisible: true)] + UserMenuItem.allCases.filter { $0 != .report }.map { .item($0, isVisible: true) } + [.more]).groups

        #expect(UserMenuItem.defaultLayout.groups.relationFailureSlots(waitsForReport: false) == RelationFailureSlots(relation: .follow, resolve: .follow))
        #expect(reportOnly.relationFailureSlots(waitsForReport: false) == RelationFailureSlots(relation: nil, resolve: nil))
        #expect(reportOnly.relationFailureSlots(waitsForReport: true) == RelationFailureSlots(relation: nil, resolve: .report))
        #expect(reportFirst.relationFailureSlots(waitsForReport: true) == RelationFailureSlots(relation: .follow, resolve: .report))
    }
}
