import Foundation
import Testing
@testable import SciaCore

/// プロフィールとリストの画面の文言のうち、値を埋める向きや、条件で文が変わるものを確かめる。
struct ProfileTextsTests {
    @Test func createListFailureNamesOtherAccount() {
        #expect(ListTexts.createFailure(account: nil) == "リストを作成できませんでした")
        #expect(ListTexts.createFailure(account: "@bob") == "@bobでリストを作成できませんでした")
    }

    @Test func countEmphasizesOnlyTheNumber() {
        let count = 12_345
        let text = ProfileTexts.Header.followersCount(count)

        #expect(text.text == "\(count.formatted()) フォロワー")
        #expect(text.text[text.emphasis] == count.formatted())
        #expect(ProfileTexts.Header.statusesCount(3).text == "3 投稿")
        #expect(ProfileTexts.Header.followingCount(0).text == "0 フォロー")
    }

    @Test func postsFilterValueListsWhatIsShown() {
        #expect(ProfileTexts.PostsFilter.accessibilityValue(ProfilePostsFilter(showsReplies: true, showsBoosts: true)) == "返信を表示、ブーストを表示")
        #expect(ProfileTexts.PostsFilter.accessibilityValue(ProfilePostsFilter(showsReplies: false, showsBoosts: true)) == "ブーストを表示")
        #expect(ProfileTexts.PostsFilter.accessibilityValue(ProfilePostsFilter(showsReplies: false, showsBoosts: false)) == "返信とブーストを表示しない")
    }

    @Test func pinnedLabelSkipsMissingParts() {
        #expect(ProfileTexts.Shelf.pinnedAccessibilityLabel(body: "本文", attachmentCount: 2, date: "昨日") == "本文、添付ファイル2件、昨日")
        #expect(ProfileTexts.Shelf.pinnedAccessibilityLabel(body: "本文", attachmentCount: 0, date: nil) == "本文")
    }

    @Test func followButtonTitlesCoverEveryShownState() {
        #expect(FollowState.allButtonTitles == ["フォローする", "フォローをリクエスト", "リクエスト中", "フォロー中", "プロフィールを編集"])
    }

    @Test func profileImageChangeValue() {
        #expect(ProfileImageChange.keep.accessibilityValue(isSet: true) == "設定済み")
        #expect(ProfileImageChange.keep.accessibilityValue(isSet: false) == "未設定")
        #expect(ProfileImageChange.remove.accessibilityValue(isSet: true) == "削除予定")
    }
}
