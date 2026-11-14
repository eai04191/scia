import Foundation
import Testing
@testable import SciaCore

/// 使う人に見える文言のうち、値を組み込むものと、ほかの文言と揃えるものを確かめる。
/// どのUIも同じ文言になるよう、文言はSciaCoreに置く。
@MainActor
struct UITextsTests {
    private func status(by acct: String) -> Status {
        Status(id: "1", createdAt: Date(timeIntervalSince1970: 0), account: Account(id: "2", username: "bob", acct: acct, displayName: "Bob", avatar: nil), content: "", spoilerText: "", url: nil)
    }

    @Test func replyLabelNamesTheAccount() {
        #expect(ReplyLabel.toAccount(acct: "bob@remote.example").title == "@bob@remote.exampleへの返信")
        #expect(ReplyLabel.toMe.title == "自分への返信")
        #expect(ReplyLabel.continuation.title == "続き")
        #expect(ReplyLabel.unknownAccount.title == "返信")
    }

    @Test func composeReplyChipMatchesTimelineReplyLabel() {
        let model = ComposeModel(tasks: TaskScope(), replyTo: status(by: "bob@remote.example"), myAccountID: "1") { _ in }

        #expect(model.contextChip?.title == ReplyLabel.toAccount(acct: "bob@remote.example").title)
        #expect(model.contextChip?.clearLabel == "返信をやめる")
    }

    @Test func noComposeChipForNewPost() {
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }

        #expect(model.contextChip == nil)
        #expect(model.sendButtonTitle == "投稿")
    }

    @Test func mediaCoverTitleTellsWhoCovered() {
        #expect(MediaCover.title(of: .sensitive) == "閲覧注意")
        #expect(MediaCover.title(of: nil) == "閲覧注意")
        #expect(MediaCover.title(of: .hidden) == "非表示")
        #expect(MediaCover.title(of: .filtered(["ネタバレ", "広告"])) == "フィルター: ネタバレ、広告")
        #expect(PostTexts.mediaCoverAccessibilityLabel(.hidden) == "非表示、タップして表示")
    }

    /// フィルターの警告は文を丸ごと返し、色を変える名前の範囲を添える。
    @Test func filterWarningMarksFilterNames() {
        let warning = PostTexts.filterWarning(titles: ["ネタバレ", "広告"])

        #expect(warning.text == "フィルター: ネタバレ、広告")
        #expect(warning.text[warning.emphasis] == "ネタバレ、広告")
    }

    @Test func ownFilterNoteQuotesEachFilter() {
        #expect(PostTexts.ownFilterNote(titles: ["ネタバレ", "広告"]) == "フィルター“ネタバレ”“広告”に一致")
    }

    @Test func doneTitleTellsWhichWayItChanged() {
        #expect(StatusInteractions.Action.bookmark.doneTitle(wasOn: false) == "ブックマークしました")
        #expect(StatusInteractions.Action.bookmark.doneTitle(wasOn: true) == "ブックマークを外しました")
        #expect(StatusInteractions.Action.muteConversation.doneTitle(wasOn: true) == "会話のミュートを解除しました")
        #expect(StatusInteractions.Action.pin.doneTitle(wasOn: false) == "プロフィールに固定しました")
    }

    @Test func boostWithChosenVisibilityFailsAsAdding() {
        #expect(StatusInteractions.Action.reblog.failureTitle() == "ブーストを変更できませんでした")
        #expect(StatusInteractions.Action.reblog.failureTitle(addsOnly: true) == "ブーストできませんでした")
    }

    @Test func otherAccountTitleStartsWithHandle() {
        let done = StatusInteractions.Action.favourite.doneTitle(wasOn: false)

        #expect(OtherAccountTexts.title(done, handle: "@me@example.social") == "@me@example.socialでお気に入りしました")
        #expect(OtherAccountTexts.title(done, handle: nil) == "お気に入りしました")
    }

    @Test func attachmentStatusReadsProgressOnlyWhileSending() {
        #expect(ComposeAttachmentStatus.uploading.accessibilityValue(progress: 0.5) == "アップロード中、50%")
        #expect(ComposeAttachmentStatus.uploading.accessibilityValue(progress: nil) == "アップロード中")
        #expect(ComposeAttachmentStatus.processing.accessibilityValue(progress: 0.5) == "サーバーで処理中")
        #expect(ComposeAttachmentStatus.ready.accessibilityValue(progress: 1) == nil)
    }

    @Test func viewerChipUsesAttachmentStatusTitle() {
        for status in [ComposeAttachmentStatus.exporting, .uploading, .processing, .sendingDescription, .failed, .descriptionFailed] {
            #expect(Notice.draftStatus(status) {}?.title == status.title)
        }
        #expect(Notice.draftStatus(.ready) {} == nil)
    }

    @Test func reblogVisibilityUsesComposeVisibilityNames() {
        #expect(ReblogVisibility.allCases.map(\.title) == ["アカウントのデフォルト", "公開", "ひかえめな公開", "フォロワーのみ"])
    }

    @Test func followButtonHiddenWhenFollowingIsImpossible() {
        #expect(FollowState.blocked.buttonTitle == nil)
        #expect(FollowState.loadFailed.buttonTitle == nil)
        #expect(FollowState.notFollowing(locked: true).buttonTitle == "フォローをリクエスト")
        #expect(FollowState.unknown.buttonTitle == FollowState.notFollowing(locked: false).buttonTitle)
    }

    @Test func notificationPolicyConfirmationNamesNotifications() {
        #expect(NotificationPolicy.Item.notFollowing.dropConfirmationTitle == "本当に“フォローしていないアカウントからの通知”を無視するようにしますか？")
        #expect(NotificationPolicy.Item.privateMentions.dropConfirmationTitle == "本当に“外部からの非公開の返信”を無視するようにしますか？")
    }

    @Test func searchSuggestionNamesTheTarget() {
        #expect(SearchSuggestions.Action.search("猫").title == "“猫”を検索")
        #expect(SearchSuggestions.Action.openHandle(acct: "bob@remote.example").title == "@bob@remote.exampleを開く")
        #expect(SearchSuggestions.Action.openHashtag(name: "scia").title == "#sciaを開く")
    }
}
