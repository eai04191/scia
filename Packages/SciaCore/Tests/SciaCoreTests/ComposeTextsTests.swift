import Foundation
import Testing
@testable import SciaCore

/// 投稿欄の文言のうち、複数の値を埋めるものと、条件で文が変わるものを確かめる。
struct ComposeTextsTests {
    @Test func attachmentLabelSkipsEmptyParts() {
        #expect(ComposeTexts.Attachment.accessibilityLabel(kind: .image, isSensitive: true, description: "猫") == "画像、閲覧注意、猫")
        #expect(ComposeTexts.Attachment.accessibilityLabel(kind: nil, isSensitive: false, description: "") == "メディア")
    }

    @Test func localAccountSubtitleMarksTheHandle() {
        let subtitle = CompletionTexts.localAccountSubtitle(acct: "bob@remote.example", source: .recent)

        #expect(subtitle.text == "@bob@remote.example・前にメンションした人")
        #expect(subtitle.text[subtitle.emphasis] == "@bob@remote.example")
        #expect(subtitle.text[subtitle.emphasis.upperBound...] == "・前にメンションした人")
    }

    @Test func hashtagLabelAddsNoteOnlyWhenGiven() {
        #expect(CompletionTexts.hashtagAccessibilityLabel(name: "scia") == "ハッシュタグ scia")
        #expect(CompletionTexts.hashtagAccessibilityLabel(name: "scia", note: OwnHashtag.Source.recent.title) == "ハッシュタグ scia、最近使ったタグ")
    }

    @Test func pollOptionsCountFromOne() {
        #expect(ComposeTexts.Poll.optionPlaceholder(index: 0) == "選択肢1")
        #expect(ComposeTexts.Poll.optionPlaceholder(index: 1) == "選択肢2")
        #expect(ComposeTexts.Poll.optionPlaceholder(index: 2) == "選択肢を追加")
        #expect(ComposeTexts.Poll.optionLabel(index: 2) == "選択肢3")
    }

    @Test func pollToggleTitlesShorten() {
        #expect(ComposeTexts.Poll.multipleTitle(false) == "1つ選ぶ")
        #expect(ComposeTexts.Poll.multipleTitle(true, short: true) == "複数")
        #expect(ComposeTexts.Poll.hidesTotalsTitle(true) == "結果を隠す")
        #expect(ComposeTexts.Poll.hidesTotalsTitle(false, short: true) == "表示")
    }

    @Test func languageSheetTextsFollowPurpose() {
        #expect(PostingLanguagePurpose.post.sectionTitle(of: .defaultLanguage) == "アカウントのデフォルト")
        #expect(PostingLanguagePurpose.accountDefault.sectionTitle(of: .recent) == "候補")
        #expect(PostingLanguagePurpose.accountDefault.sectionTitle(of: .all) == "すべての言語")
    }

    @Test func scheduledPostMarksTheDate() {
        let row = ComposeTexts.scheduledPost(date: "明日 9:00")

        #expect(row.text[row.emphasis] == "明日 9:00")
        #expect(row.text[row.emphasis.upperBound...] == "に投稿")
    }

    @Test func restValueReadsPartsInOrder() {
        let value = ComposeTexts.restAccessibilityValue(chipTitle: "@bobへの返信", attachmentCount: 2, onlyImages: true, hasFailedAttachment: true, scheduledDate: "明日 9:00", text: "本文", isPosting: true)

        #expect(value == "@bobへの返信、画像2枚を添付、送信できなかった添付があります、明日 9:00に予約、本文、予約中")
    }

    @Test func restValueWithoutChipOrSchedule() {
        let value = ComposeTexts.restAccessibilityValue(chipTitle: nil, attachmentCount: 1, onlyImages: false, hasFailedAttachment: false, scheduledDate: nil, text: "本文", isPosting: true)

        #expect(value == "メディア1件を添付、本文、投稿中")
    }
}
