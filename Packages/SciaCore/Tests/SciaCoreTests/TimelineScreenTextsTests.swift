import Foundation
import Testing
@testable import SciaCore

/// タイムライン、通知、予約投稿の画面の文言のうち、複数の値を埋めるものと、条件で文が変わるものを確かめる。
struct TimelineScreenTextsTests {
    @Test func notificationHeaderMarksNameAndOtherAccounts() {
        let header = PostTexts.notificationHeader(NotificationAppearance(.favourite), name: "Bob", otherAccountCount: 2, reactionEmoji: nil)

        #expect(header.text == "Bobとほか2人がお気に入りに登録しました")
        #expect(header.name.map { String(header.text[$0]) } == "Bob")
        #expect(header.otherAccounts.map { String(header.text[$0]) } == "ほか2人")
        #expect(header.reactionEmoji == nil)
    }

    @Test func notificationHeaderPutsPhraseAroundName() {
        let header = PostTexts.notificationHeader(NotificationAppearance(.quotedUpdate), name: "Bob", otherAccountCount: nil, reactionEmoji: nil)

        #expect(header.text == "引用した投稿をBobが編集しました")
        #expect(header.name.map { String(header.text[$0]) } == "Bob")
        #expect(header.otherAccounts == nil)
    }

    @Test func notificationHeaderWithoutNameHasNoRanges() {
        let header = PostTexts.notificationHeader(NotificationAppearance(.poll), name: "Bob", otherAccountCount: 2, reactionEmoji: nil)

        #expect(header.text == "投票が終了しました")
        #expect(header.name == nil)
        #expect(header.otherAccounts == nil)
    }

    @Test func notificationHeaderMarksReactionEmoji() {
        // 名前が複数バイトの文字を含んでも、範囲が名前と絵文字からずれない。
        let header = PostTexts.notificationHeader(NotificationAppearance(.emojiReaction), name: "Bob👍", otherAccountCount: 1, reactionEmoji: ":blobcat:")

        #expect(header.text == "Bob👍とほか1人が:blobcat:でリアクションしました")
        #expect(header.name.map { String(header.text[$0]) } == "Bob👍")
        #expect(header.otherAccounts.map { String(header.text[$0]) } == "ほか1人")
        #expect(header.reactionEmoji.map { String(header.text[$0]) } == ":blobcat:")
    }

    @Test func timeAccessibilityTextPutsStatesBeforeTime() {
        #expect(PostTexts.timeAccessibilityText("3分前", isEdited: false, isTranslated: false, isTranslating: false, visibility: .public) == "3分前")
        #expect(
            PostTexts.timeAccessibilityText("3分前", isEdited: true, isTranslated: true, isTranslating: true, visibility: .unlisted)
                == "\(VisibilityOption(.unlisted).title)、翻訳済み、編集済み、3分前"
        )
        #expect(PostTexts.timeAccessibilityText("3分前", isEdited: false, isTranslated: false, isTranslating: true, visibility: .public) == "翻訳中、3分前")
    }

    @Test func actionBarButtonValueSkipsMissingParts() {
        #expect(PostTexts.actionBarButtonValue(isOn: true, count: 1200) == "済み、\(1200.formatted())件")
        #expect(PostTexts.actionBarButtonValue(isOn: false, count: 3) == "3件")
        #expect(PostTexts.actionBarButtonValue(isOn: false, count: nil) == "")
    }

    @Test func linkCardAccessibilityLabelSkipsEmptyParts() {
        #expect(PostTexts.linkCardAccessibilityLabel(title: "題", site: "example.com") == "リンク、題、example.com")
        #expect(PostTexts.linkCardAccessibilityLabel(title: nil, site: "") == "リンク")
    }

    @Test func reactionGlowNamesWhatWasDone() {
        #expect(PostTexts.reactionGlowAccessibilityText(isReblogged: true, isFavourited: true) == "ブースト済み、お気に入り済み")
        #expect(PostTexts.reactionGlowAccessibilityText(isReblogged: false, isFavourited: true) == "お気に入り済み")
        #expect(PostTexts.reactionGlowAccessibilityText(isReblogged: false, isFavourited: false) == nil)
    }

    @Test func subtitleAddsStreamingOutage() {
        let texts = TimelineTexts(dumpName: "test", title: "題", subtitle: "添え書き", empty: "", reachedEnd: "", unreadable: "")

        #expect(texts.subtitle(showsStreamingOutage: true) == "添え書き・ストリーミング未接続")
        #expect(texts.subtitle(showsStreamingOutage: false) == "添え書き")
        #expect(TimelineTexts.home.subtitle(showsStreamingOutage: false) == nil)
    }

    @Test func unreadableDetailTellsWhatTapDoes() {
        #expect(TimelineScreenTexts.unreadableDetail(isCrashQuarantined: true, opensInBrowser: true) == "表示中にSciaが終了したため隠しています。タップすると詳細を表示します。")
        #expect(TimelineScreenTexts.unreadableDetail(isCrashQuarantined: false, opensInBrowser: true) == "サーバーから届いた内容を読めませんでした。タップするとブラウザで開きます。")
        #expect(TimelineScreenTexts.unreadableDetail(isCrashQuarantined: false, opensInBrowser: false) == "サーバーから届いた内容を読めませんでした。")
    }

    @Test func scheduledContextJoinsParts() {
        #expect(ScheduledStatusTexts.context([.reply, .quote, .poll]) == "返信・引用・投票")
        #expect(ScheduledStatusTexts.context([.poll]) == "投票")
    }

    @Test func streamingStateShowsNoteInsteadOfTitle() {
        #expect(StreamingStatusTexts.streaming(.connected) == "接続済み")
        #expect(StreamingStatusTexts.streaming(.connecting) == "接続中")
        #expect(StreamingStatusTexts.streaming(.polling) == "ポーリング中")
        #expect(StreamingStatusTexts.streaming(.stopped) == "未接続")
        #expect(StreamingStatusTexts.streaming(.loginRequired) == "ログインが必要")
        #expect(StreamingStatusTexts.streaming(nil) == "未接続")
    }
}
