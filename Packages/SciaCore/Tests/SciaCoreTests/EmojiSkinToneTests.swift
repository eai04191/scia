import Foundation
import SciaCore
import SciaTesting
import Testing

/// 絵文字の肌の色。決まりはdocs/compose.mdの「絵文字の肌の色」にある。
struct EmojiSkinToneTests {
    private func emoji(_ text: String) throws -> StandardEmoji {
        try #require(StandardEmojiCatalog.groups.flatMap(\.emojis).first { $0.emoji == text })
    }

    /// 1人の絵文字は、肌の色を付けた並びに替わる。名前と検索の言葉は変えない。肌の色を外すと元に戻る。
    @Test func singlePersonEmojiTakesTheTone() throws {
        let thumbsUp = try emoji("👍")
        let toned = thumbsUp.withSkinTone(.medium)

        #expect(toned.emoji == "👍🏽")
        #expect(toned.name == thumbsUp.name)
        #expect(toned.currentSkinTones.first == .medium)
        #expect(toned.withSkinTone(.none) == thumbsUp)
        #expect(toned.withSkinTone(.dark).emoji == "👍🏿")
    }

    /// 2人の絵文字は、2人それぞれの色を選べる。色が違う握手は、元の絵文字と別の文字で組んだ並びになる。
    @Test func pairEmojiTakesTwoTones() throws {
        let handshake = try emoji("🤝")

        #expect(handshake.skinTones?.isPair == true)
        #expect(handshake.withSkinTone(.light).emoji == "🤝🏻")
        let mixed = handshake.withSkinTones(.light, .dark)
        #expect(mixed.emoji == "🫱🏻‍🫲🏿")
        #expect(mixed.currentSkinTones.first == .light && mixed.currentSkinTones.second == .dark)
    }

    /// 片方だけに肌の色を付けた並びはUnicodeにないので、どちらかが付けないなら2人とも付けない。
    @Test func pairWithoutEitherToneIsUntoned() throws {
        let handshake = try emoji("🤝")

        #expect(handshake.withSkinTones(.light, .none) == handshake)
        #expect(handshake.withSkinTones(.none, .dark) == handshake)
    }

    /// 端末が2人の色の違う並びを描けないときは、2人同じ色の5つだけを選べる絵文字として扱う。
    @Test func pairLimitedToSameToneOffersOnlyMatchingTones() throws {
        let handshake = try emoji("🤝").limitingSkinTonesToSameForBoth()

        #expect(handshake.skinTones == .single(["🤝🏻", "🤝🏼", "🤝🏽", "🤝🏾", "🤝🏿"]))
        #expect(handshake.withSkinTones(.light, .dark).emoji == "🤝🏻")
        #expect(handshake.withSkinTone(.dark).currentSkinTones.second == .dark)
    }

    /// 端末が描けるかを確かめる見本は、2人の絵文字では同じ色の並びと違う色の並びを別々に持つ。
    @Test func samplesSeparateSameAndMixedTones() throws {
        #expect(try emoji("👍").skinToneSamples?.same == "👍🏻")
        #expect(try emoji("👍").skinToneSamples?.mixed == nil)
        #expect(try emoji("🤝").skinToneSamples?.same == "🤝🏻")
        #expect(try emoji("🤝").skinToneSamples?.mixed == "🫱🏻‍🫲🏼")
        #expect(try emoji("😀").skinToneSamples == nil)
    }

    /// 肌の色を変えられない絵文字は、そのまま。
    @Test func emojiWithoutTonesIsUnchanged() throws {
        let grinning = try emoji("😀")

        #expect(grinning.skinTones == nil)
        #expect(grinning.withSkinTone(.dark) == grinning)
    }

    /// 既定の肌の色は、肌の色を変えられる絵文字だけに付き、並びと数は変えない。
    @Test func defaultToneAppliesToTheWholeList() {
        let groups = StandardEmojiCatalog.groups
        let toned = groups.withSkinTone(.mediumDark)

        #expect(toned.map(\.emojis.count) == groups.map(\.emojis.count))
        let changed = zip(groups.flatMap(\.emojis), toned.flatMap(\.emojis)).filter { $0.emoji != $1.emoji }
        #expect(changed.count == groups.flatMap(\.emojis).filter { $0.skinTones != nil }.count)
        #expect(changed.allSatisfy { $1.untonedEmoji == $0.emoji })
    }

    /// 最近使った絵文字は、使ったときの肌の色のまま出す。リストが別の既定の色で並んでいても、色なしで使ったものは色なしで出す。
    @Test func recentEmojisKeepTheToneTheyWereUsedWith() {
        let groups = StandardEmojiCatalog.groups.withSkinTone(.medium)
        let sections = EmojiPalette.sections(emojis: [], standardGroups: groups, recentKeys: ["👍🏿", "👍", "👍🏽", "🫱🏻‍🫲🏿"], recentLimit: 10)

        #expect(sections.first?.kind == .recent)
        #expect(sections.first?.emojis.map(\.recentKey) == ["👍🏿", "👍", "👍🏽", "🫱🏻‍🫲🏿"])
    }

    /// 個人セットの絵文字は応答の文字のまま並べるが、肌の色を変えられることは引き継ぐ。既定の肌の色を付けていても、長押しで色を選べるようにするため。
    /// 最近使ったものに同じ絵文字があっても、同じく引き継ぐ。
    @Test func personalSetEmojiKeepsItsTextAndCanStillChangeTone() throws {
        let groups = StandardEmojiCatalog.groups.withSkinTone(.dark)
        let personal = PersonalEmojiSet(categories: [.init(id: "a", name: "a", entries: [
            .init(emoji: .standard(StandardEmoji(emoji: "👍", name: "", keywords: [], version: ""))),
            .init(emoji: .standard(StandardEmoji(emoji: "👋🏻", name: "", keywords: [], version: ""))),
        ])])
        let sections = EmojiPalette.sections(emojis: [], personal: personal, standardGroups: groups, recentKeys: ["👍"], recentLimit: 10)
        func standards(_ kind: (EmojiPaletteSection.Kind) -> Bool) -> [StandardEmoji] {
            sections.filter { kind($0.kind) }.flatMap(\.emojis).compactMap { if case .standard(let emoji) = $0 { emoji } else { nil } }
        }
        let inPersonal = standards { if case .personal = $0 { true } else { false } }
        let inRecent = standards { $0 == .recent }

        #expect(inPersonal.map(\.emoji) == ["👍", "👋🏻"])
        #expect(inPersonal.allSatisfy { $0.skinTones != nil })
        #expect(inPersonal.last?.currentSkinTones.first == .light)
        #expect(inRecent.map(\.emoji) == ["👍"])
        #expect(inRecent.first?.skinTones != nil)
    }

    /// 肌の色を付けた絵文字は、読み上げで色を区別できるよう、肌の色の名前を持つ。付けていなければ持たない。
    @Test func tonedEmojiDescribesItsTone() throws {
        let thumbsUp = try emoji("👍")
        let handshake = try emoji("🤝")

        #expect(thumbsUp.skinToneDescription == nil)
        #expect(thumbsUp.withSkinTone(.dark).skinToneDescription == "濃い肌色")
        #expect(handshake.withSkinTone(.light).skinToneDescription == "薄い肌色")
        #expect(handshake.withSkinTones(.light, .dark).skinToneDescription == "薄い肌色、濃い肌色")
    }

    /// 既定の肌の色は、設定に残る。
    @MainActor
    @Test(.scratch) func defaultToneIsSaved() {
        let defaults = TestScratch.defaults("EmojiSkinToneTests")
        #expect(AppSettings(defaults: defaults).emojiSkinTone == .none)

        AppSettings(defaults: defaults).emojiSkinTone = .mediumLight

        #expect(AppSettings(defaults: defaults).emojiSkinTone == .mediumLight)
    }
}
