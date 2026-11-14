import Foundation
import Testing
@testable import SciaCore

/// 設定の画面の文言のうち、条件で文が変わるもの。
struct SettingsTextsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func filter(expiresAt: Date?) -> ServerFilter {
        ServerFilter(id: "1", title: "ネタバレ", context: [.home], filterAction: .warn, expiresAt: expiresAt, keywords: [])
    }

    @Test func filterRowDetailShowsExpiry() {
        let warn = FilterResult.Action.warn.title
        #expect(filter(expiresAt: nil).rowDetail(now: now) == warn)
        // 期限ちょうどは切れている。
        #expect(filter(expiresAt: now).rowDetail(now: now) == "\(warn)・期限切れ")
        let later = now.addingTimeInterval(3600)
        #expect(filter(expiresAt: later).rowDetail(now: now) == "\(warn)・\(later.formatted(date: .abbreviated, time: .shortened))まで")
    }

    @Test func streamingSubscriptionTitleFollowsTabNames() {
        #expect(StreamingSubscription.user.title(listTitles: [:]) == "ホームと通知")
        #expect(StreamingSubscription(stream: "public:local").title(listTitles: [:]) == "ローカル")
        #expect(StreamingSubscription.list("7").title(listTitles: ["7": "友だち"]) == "リスト“友だち”")
        // タブの並びにないリストは、名前を出さない。
        #expect(StreamingSubscription.list("8").title(listTitles: ["7": "友だち"]) == "リスト")
        #expect(StreamingSubscription.hashtag("scia").title(listTitles: [:]) == "#scia")
        #expect(StreamingSubscription(stream: "public:media").title(listTitles: [:]) == "public:media")
    }

    @Test func unprocessableFormatValueNamesServerVersion() {
        #expect(SettingsTexts.Connection.unprocessableFormatValue(serverVersion: "4.3.0") == "JPEGで送っています・4.3.0")
        #expect(SettingsTexts.Connection.unprocessableFormatValue(serverVersion: "") == "JPEGで送っています・版が不明")
    }

    @Test func appearanceNoteShowsOffsetFromStandard() {
        #expect(AppearanceCatalog.bodyText.note(for: 0) == "標準")
        #expect(AppearanceCatalog.bodyText.note(for: 2) == "標準+2")
        #expect(AppearanceCatalog.bodyText.note(for: -1.5) == "標準−1.5")
        #expect(AppearanceCatalog.namePrimaryText.note(for: 0) == "本文と同じ")
        #expect(AppearanceCatalog.namePrimaryText.note(for: 3) == "本文+3")
        #expect(AppearanceCatalog.bodyTruncationThreshold.note(for: 0) == "切らない")
        #expect(AppearanceCatalog.bodyTruncationThreshold.note(for: 5) == nil)
        #expect(AppearanceCatalog.emojiOnlyLimit.note(for: 0) == "大きくしない")
    }

    /// 割合の項目の説明は項目ごとに決まり、縦長の比率の説明がほかの割合の項目に出ない。
    @Test func ratioNotesBelongToTheirItems() {
        #expect(AppearanceCatalog.mediaTallestAspectRatio.ratioNote == "小さいほど縦長のまま表示")
        #expect(AppearanceCatalog.reactionGlowIconOpacity.ratioNote == nil)
        // カスタム絵文字の倍率は、見出しに割合の基準を書かず、1がどの大きさかを説明に出す。名前の行と本文で同じ説明にする。
        for item in [AppearanceCatalog.customEmojiScale, AppearanceCatalog.nameCustomEmojiScale] {
            #expect(item.ratioNote == "1で絵文字と同じ大きさ", "\(item.id)")
        }
        // 普通の絵文字の倍率は、1でいつもの大きさなのが倍率から分かるので、説明を出さない。
        for item in [AppearanceCatalog.unicodeEmojiScale, AppearanceCatalog.nameUnicodeEmojiScale, AppearanceCatalog.emojiOnlyScale] {
            #expect(item.ratioNote == nil, "\(item.id)")
        }
        #expect(AppearanceCatalog.linkCardImageWidthRatio.ratioNote == "画像はカードの高さの正方形より広くならない")
    }
}
