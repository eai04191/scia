import Foundation
import Testing
@testable import SciaCore

/// アカウントの画面一式の文言のうち、値を埋める位置や条件で文が変わるもの。
struct SessionTextsTests {
    private let actor = Account(id: "2", username: "bob", acct: "bob@example.social", displayName: "Bob", avatar: nil)

    @Test func pendingRequestsReadsCountOnlyWhenSomeoneIsWaiting() {
        #expect(SessionTexts.pendingRequests(countText: nil) == "保留中の通知")
        #expect(SessionTexts.pendingRequests(countText: "100+") == "保留中の通知、100+人")
    }

    @Test func cannotSeeNamesReplyTargetOrQuotedPost() {
        #expect(SessionTexts.cannotSee(username: "alice", isReply: true) == "@aliceからは返信先の投稿が見られません。")
        #expect(SessionTexts.cannotSee(username: "alice", isReply: false) == "@aliceからは引用元の投稿が見られません。")
    }

    @Test func autoTranslationSaysWhetherExcluded() {
        #expect(SessionTexts.autoTranslation(handle: "@alice", isExcluded: true) == "@aliceを自動翻訳しません")
        #expect(SessionTexts.autoTranslation(handle: "@alice", isExcluded: false) == "@aliceを自動翻訳します")
    }

    @Test func logOutMessageAddsDraftOnlyWhenWritten() {
        let base = "このデバイスからアカウントの情報を削除します。もう一度使うにはログインし直す必要があります。"
        #expect(AccountSwitchTexts.LoggingOut.message(discardsDraft: false) == base)
        #expect(AccountSwitchTexts.LoggingOut.message(discardsDraft: true) == base + "書きかけの投稿も破棄されます。")
    }

    @Test func differentAccountPutsActualFirst() {
        #expect(AccountSwitchTexts.differentAccountLoggedIn(expected: "@a@x", actual: "@b@y") == "@b@yでログインされました。@a@xでログインし直してください。")
    }

    @Test func tickerReadsActionAndSubject() {
        let image = MediaAttachment(id: "1", type: .image, url: URL(string: "https://example.social/1.png"), previewUrl: URL(string: "https://example.social/1-small.png"))
        func label(_ kind: MastodonNotification.Kind, _ subject: StatusBarTickerItem.Subject, emoji: ReactionEmoji? = nil) -> String {
            StatusBarTickerItem(id: "1", kind: kind, account: actor, subject: subject, reactionEmoji: emoji).accessibilityLabel
        }

        #expect(label(.favourite, .text(RichText.plain("本文", emojis: []))) == "Bobがお気に入りに登録しました。本文")
        #expect(label(.favourite, .media(image, isSensitive: false, isImageOnly: true)) == "Bobがお気に入りに登録しました。画像だけの投稿")
        #expect(label(.favourite, .media(image, isSensitive: false, isImageOnly: false)) == "Bobがお気に入りに登録しました。メディアだけの投稿")
        #expect(label(.follow, .handle("@bob@example.social")) == "Bobにフォローされました。@bob@example.social")
        #expect(label(.poll, .none) == "投票が終了しました")
        #expect(label(.quotedUpdate, .none) == "引用した投稿をBobが編集しました")
        #expect(label(.emojiReaction, .none, emoji: ReactionEmoji(name: "🎉")) == "Bobが🎉でリアクションしました")
        #expect(label(.emojiReaction, .none, emoji: ReactionEmoji(name: "party_parrot")) == "Bobが:party_parrot:でリアクションしました")
    }
}
