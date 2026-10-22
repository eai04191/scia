import Foundation
import Testing
@testable import SciaCore

/// 返信の札を投稿の情報だけで決められることと、隣り合う返信の行を線でつなぐ判定を確かめる。
struct ReplyLabelTests {
    private let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
    private let bob = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: nil)

    private func status(_ id: Int, by account: Account, replyingTo parent: (id: Int, accountID: String)? = nil, mentions: [Account] = [], reblog: Status? = nil) -> Status {
        Status(
            id: String(id),
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            account: account,
            content: "",
            spoilerText: "",
            url: nil,
            mentions: mentions.map { Mention(id: $0.id, username: $0.username, url: nil, acct: $0.acct) },
            inReplyToId: parent.map { String($0.id) },
            inReplyToAccountId: parent?.accountID,
            reblog: reblog
        )
    }

    @Test func noLabelForNonReply() {
        #expect(ReplyLabel(status: status(1, by: alice), myAccountID: "9") == nil)
    }

    @Test func labelsReplyWithHandleFromMentions() {
        let reply = status(2, by: alice, replyingTo: (1, bob.id), mentions: [bob])
        #expect(ReplyLabel(status: reply, myAccountID: "9") == .toAccount(acct: "bob@remote.example"))
    }

    @Test func labelsReplyToOwnPostAsContinuation() {
        let reply = status(2, by: alice, replyingTo: (1, alice.id))
        #expect(ReplyLabel(status: reply, myAccountID: alice.id) == .continuation)
    }

    @Test func labelsReplyToMe() {
        let reply = status(2, by: bob, replyingTo: (1, alice.id), mentions: [alice])
        #expect(ReplyLabel(status: reply, myAccountID: alice.id) == .toMe)
    }

    @Test func labelsReplyWithoutMentionAsUnknownAccount() {
        let reply = status(2, by: alice, replyingTo: (1, bob.id))
        #expect(ReplyLabel(status: reply, myAccountID: "9") == .unknownAccount)
    }

    @Test func connectsReplyDirectlyAboveItsParentInNewestFirstList() {
        let parent = status(1, by: bob)
        let reply = status(2, by: alice, replyingTo: (1, bob.id))
        let other = status(3, by: bob)
        let connections = ReplyConnection.connections(in: [.status(other), .status(reply), .status(parent)])
        #expect(connections[.status("3")] == nil)
        #expect(connections[.status("2")] == ReplyConnection(below: true))
        #expect(connections[.status("1")] == ReplyConnection(above: true))
    }

    @Test func marksParentAboveInOldestFirstList() {
        let parent = status(1, by: bob)
        let reply = status(2, by: alice, replyingTo: (1, bob.id))
        let connections = ReplyConnection.connections(in: [.status(parent), .status(reply)])
        #expect(connections[.status("1")] == ReplyConnection(below: true))
        #expect(connections[.status("2")] == ReplyConnection(above: true, parentIsAbove: true))
    }

    @Test func doesNotConnectSeparatedRows() {
        let parent = status(1, by: bob)
        let reply = status(3, by: alice, replyingTo: (1, bob.id))
        let connections = ReplyConnection.connections(in: [.status(reply), .status(status(2, by: bob)), .status(parent)])
        #expect(connections.isEmpty)
    }

    @Test func doesNotConnectBoostsOrPinnedPosts() {
        let parent = status(1, by: bob)
        let reply = status(2, by: alice, replyingTo: (1, bob.id))
        let boostOfReply = status(5, by: bob, reblog: reply)
        #expect(ReplyConnection.connections(in: [.status(boostOfReply), .status(parent)]).isEmpty)
        #expect(ReplyConnection.connections(in: [.pinned(reply), .status(parent)]).isEmpty)
    }
}
