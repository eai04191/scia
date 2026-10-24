import Foundation
import Testing
@testable import SciaCore

struct CompletionTokenTests {
    /// `|`をカーソルの位置として取り除き、その位置の語を切り出す。
    private func token(_ marked: String, kinds: Set<CompletionKind> = Set(CompletionKind.allCases), markedRange: Range<Int>? = nil, minimum: [CompletionKind: Int] = [:]) -> CompletionToken? {
        let (text, cursor) = split(marked)
        return CompletionTokenizer.token(in: text, selection: cursor ..< cursor, markedRange: markedRange, kinds: kinds, minimumQueryLength: minimum)
    }

    private func split(_ marked: String) -> (String, Int) {
        let parts = marked.components(separatedBy: "|")
        return (parts.joined(), parts[0].utf16.count)
    }

    // MARK: - メンション

    @Test func mentionAtStartOfText() throws {
        let token = try #require(token("@ea|"))
        #expect(token.kind == .mention)
        #expect(token.query == "ea")
        #expect(token.range == 0 ..< 3)
        #expect(!token.needsLeadingSpace)
    }

    @Test func mentionAfterSpace() throws {
        let token = try #require(token("hello @bob|"))
        #expect(token.query == "bob")
        #expect(token.range == 6 ..< 10)
    }

    @Test func mentionWithDomain() throws {
        let token = try #require(token("@bob@remote.exa|"))
        #expect(token.query == "bob@remote.exa")
        #expect(token.range == 0 ..< 15)
    }

    /// 2つ目の`@`を打った直後も、1つ目から語にする。
    @Test func mentionRightAfterDomainSeparator() throws {
        let token = try #require(token("@bob@|"))
        #expect(token.query == "bob@")
        #expect(token.range.lowerBound == 0)
    }

    @Test func fullWidthAtSign() throws {
        let token = try #require(token("＠bob|"))
        #expect(token.kind == .mention)
        #expect(token.query == "bob")
    }

    /// 記号だけでは出さない。打った文字数がチューニングの値に満たなければ出さない。
    @Test func requiresMinimumQueryLength() {
        #expect(token("@|") == nil)
        #expect(token("@b|", minimum: [.mention: 2]) == nil)
        #expect(token("@bo|", minimum: [.mention: 2]) != nil)
    }

    /// 文字数を0にすると、記号だけでも語にする。投稿欄では、記号だけの時点から手元の候補を出すため。
    @Test func markAloneWithZeroMinimum() throws {
        let mention = try #require(token("@|", minimum: [.mention: 0]))
        #expect(mention.query == "")
        #expect(mention.range == 0 ..< 1)
        let hashtag = try #require(token("猫 #|", minimum: [.hashtag: 0]))
        #expect(hashtag.query == "")
        #expect(!hashtag.needsLeadingSpace)
        #expect(try #require(token("猫@|", minimum: [.mention: 0])).needsLeadingSpace)
        #expect(token("mail@|", minimum: [.mention: 0]) == nil)
        #expect(token("@.|", minimum: [.mention: 0]) == nil)
    }

    /// 語の途中にカーソルがあれば、語の終わりまでを置き換える。
    @Test func cursorInsideWordCoversWholeWord() throws {
        let token = try #require(token("@bo|b hello"))
        #expect(token.query == "bob")
        #expect(token.range == 0 ..< 4)
    }

    /// リモートのメンションのユーザー名を途中で書き直すときは、後ろのドメインまで置き換える。
    @Test func cursorInsideUsernameCoversDomain() throws {
        let token = try #require(token("@bo|b@remote.example です"))
        #expect(token.query == "bob@remote.example")
        #expect(token.range == 0 ..< 19)
    }

    /// 文の終わりの`.`は、カーソルより後ろならユーザー名に含めない。サーバーの`MENTION_RE`も末尾の`.`を含めない。
    @Test func trailingPeriodIsNotPartOfMention() throws {
        let (text, _) = split("Hello @bo|b.")
        let token = try #require(token("Hello @bo|b."))
        #expect(token.query == "bob")
        let insertion = CompletionTokenizer.insertion(of: "@bob", replacing: token, in: text)
        #expect(insertion.range == 6 ..< 10)
        #expect(try #require(self.token("@bo|b@remote.example.")).query == "bob@remote.example")
    }

    /// カーソルが語の中になければ出さない。
    @Test func cursorAfterSpaceIsOutsideWord() {
        #expect(token("@bob |") == nil)
        #expect(token("@bob\n|") == nil)
    }

    /// メールアドレスやURLの中の`@`では出さない。
    @Test func ignoresEmailAndURL() {
        #expect(token("mail me at bob@exa|") == nil)
        #expect(token("https://example.social/@bo|") == nil)
    }

    /// 日本語の直後では、サーバーがメンションとして読まないので、空白を入れて補完する。
    @Test func mentionRightAfterJapaneseNeedsSpace() throws {
        let token = try #require(token("こんにちは@bo|"))
        #expect(token.query == "bo")
        #expect(token.needsLeadingSpace)
        #expect(token.range == 5 ..< 8)
    }

    /// 括弧や読点の後は、サーバーがそのまま読むので空白を入れない。
    @Test func mentionAfterPunctuationNeedsNoSpace() throws {
        #expect(try #require(token("（@bo|")).needsLeadingSpace == false)
        #expect(try #require(token("はい、@bo|")).needsLeadingSpace == false)
    }

    /// ユーザー名は英数字なので、日本語が続けば語ではない。
    @Test func japaneseAfterMentionIsNotUsername() {
        #expect(token("@ぼぶ|") == nil)
    }

    // MARK: - ハッシュタグ

    @Test func hashtagWithJapanese() throws {
        let token = try #require(token("今日は #猫のい|"))
        #expect(token.kind == .hashtag)
        #expect(token.query == "猫のい")
        #expect(!token.needsLeadingSpace)
    }

    /// 日本語は1文字を2文字と数え、漢字1文字のタグでも候補を出す。
    @Test func countsNonASCIIAsTwo() {
        #expect(token("#猫|", minimum: [.hashtag: 2]) != nil)
        #expect(token("#n|", minimum: [.hashtag: 2]) == nil)
        #expect(token("#猫|", minimum: [.hashtag: 3]) == nil)
    }

    @Test func fullWidthHashSign() throws {
        #expect(try #require(token("＃猫|")).kind == .hashtag)
    }

    /// サーバーは空白の後のタグしか読まない。日本語の直後なら空白を入れる。
    @Test func hashtagRightAfterJapaneseNeedsSpace() throws {
        let token = try #require(token("今日は#猫|"))
        #expect(token.needsLeadingSpace)
        #expect(token.range == 3 ..< 5)
    }

    /// URLの`#`の後では出さない。
    @Test func ignoresURLFragment() {
        #expect(token("https://example.com/page#sec|") == nil)
    }

    @Test func hashtagSeparators() throws {
        #expect(try #require(token("#猫・犬|")).query == "猫・犬")
        #expect(try #require(token("#cat_dog|")).query == "cat_dog")
    }

    // MARK: - カスタム絵文字

    @Test func emoji() throws {
        let token = try #require(token("いいね :blob|"))
        #expect(token.kind == .emoji)
        #expect(token.query == "blob")
        #expect(!token.needsLeadingSpace)
    }

    /// 時刻やURLの`:`では出さない。サーバーが絵文字として読む`/`や`=`の直後でも、URLの一部とみなす。
    @Test func ignoresTimeAndScheme() {
        #expect(token("12:30|") == nil)
        #expect(token("http:ab|") == nil)
        #expect(token("https://example.com/:bl|") == nil)
        #expect(token("?icon=:bl|") == nil)
    }

    /// 日本語の直後と、前の絵文字の直後は、サーバーが読まないので空白を入れる。
    @Test func emojiRightAfterJapaneseOrEmojiNeedsSpace() throws {
        #expect(try #require(token("いいね:blob|")).needsLeadingSpace)
        #expect(try #require(token(":blobcat::blo|")).needsLeadingSpace)
    }

    /// 閉じの`:`まで打ったら出さない。語の途中なら、閉じの`:`も置き換える範囲に入れる。
    @Test func closingColon() throws {
        #expect(token(":blob:|") == nil)
        let token = try #require(token(":bl|ob: です"))
        #expect(token.query == "blob")
        #expect(token.range == 0 ..< 6)
    }

    /// 絵文字を0文字から出す設定でも、`:`だけで出し、絵文字を打ち終えた閉じの`:`では出さない。
    @Test func emojiWithZeroMinimum() throws {
        let token = try #require(token("例:|", minimum: [.emoji: 0]))
        #expect(token.query == "")
        #expect(token.needsLeadingSpace)
        #expect(self.token(":blob:|", minimum: [.emoji: 0]) == nil)
    }

    @Test func emojiNeedsShortcodeCharacters() {
        #expect(token(":ねこ|") == nil)
    }

    // MARK: - 種類と変換中の文字

    /// 注意書きの欄では絵文字だけを補完する。
    @Test func restrictsKinds() {
        #expect(token("@bob|", kinds: [.emoji]) == nil)
        #expect(token("#tag|", kinds: [.emoji]) == nil)
        #expect(token(":blob|", kinds: [.emoji]) != nil)
    }

    /// 変換中の文字があるときは出さない。確定してから読み直す。
    @Test func ignoresWhileMarkedTextExists() {
        #expect(token("#ねこ|", markedRange: 1 ..< 3) == nil)
        #expect(token("#ねこ|", markedRange: nil) != nil)
    }

    @Test func ignoresNonEmptySelection() {
        #expect(CompletionTokenizer.token(in: "@bob", selection: 1 ..< 4) == nil)
    }

    /// 絵文字（サロゲートペア）の後ろでも、位置をUTF-16で数える。
    @Test func countsPositionsInUTF16() throws {
        let token = try #require(token("🐱 @bo|"))
        #expect(token.range == 3 ..< 6)
    }

    /// 書記素の途中の位置からは切り出さない。
    @Test func ignoresPositionInsideCharacter() {
        #expect(CompletionTokenizer.token(in: "🐱@bo", selection: 1 ..< 1) == nil)
    }

    // MARK: - 置き換え

    /// ＋で入れる記号は、サーバーが読む位置になるよう、必要なときだけ前に空白を入れ、後ろには足さない。
    @Test func markInsertion() {
        #expect(CompletionTokenizer.insertion(ofMark: .hashtag, at: 0 ..< 0, in: "") == CompletionInsertion(range: 0 ..< 0, text: "#", cursor: 1))
        #expect(CompletionTokenizer.insertion(ofMark: .hashtag, at: 2 ..< 2, in: "猫 ") == CompletionInsertion(range: 2 ..< 2, text: "#", cursor: 3))
        #expect(CompletionTokenizer.insertion(ofMark: .hashtag, at: 1 ..< 1, in: "猫") == CompletionInsertion(range: 1 ..< 1, text: " #", cursor: 3))
        #expect(CompletionTokenizer.insertion(ofMark: .hashtag, at: 2 ..< 2, in: "猫。") == CompletionInsertion(range: 2 ..< 2, text: " #", cursor: 4))
        #expect(CompletionTokenizer.insertion(ofMark: .mention, at: 2 ..< 2, in: "猫。") == CompletionInsertion(range: 2 ..< 2, text: "@", cursor: 3))
        #expect(CompletionTokenizer.insertion(ofMark: .mention, at: 3 ..< 3, in: "abc") == CompletionInsertion(range: 3 ..< 3, text: " @", cursor: 5))
        // 選んでいる範囲は、打ったときと同じく記号に置き換える。
        #expect(CompletionTokenizer.insertion(ofMark: .mention, at: 2 ..< 5, in: "a bcd") == CompletionInsertion(range: 2 ..< 5, text: "@", cursor: 3))
        let afterInsertion = "猫 #"
        #expect(CompletionTokenizer.token(in: afterInsertion, selection: 3 ..< 3, minimumQueryLength: [.hashtag: 0]) != nil)
    }

    @Test func insertionAddsTrailingSpace() throws {
        let (text, _) = split("hello @bo|")
        let token = try #require(token("hello @bo|"))
        let insertion = CompletionTokenizer.insertion(of: "@bob@remote.example", replacing: token, in: text)
        #expect(insertion.range == 6 ..< 9)
        #expect(insertion.text == "@bob@remote.example ")
        #expect(insertion.cursor == 6 + 20)
    }

    /// 後ろに空白があれば足さず、カーソルを空白の後ろに置く。
    @Test func insertionReusesFollowingSpace() throws {
        let (text, _) = split("#ne| です")
        let token = try #require(token("#ne| です"))
        let insertion = CompletionTokenizer.insertion(of: "#neko", replacing: token, in: text)
        #expect(insertion.text == "#neko")
        #expect(insertion.cursor == 6)
    }

    /// 日本語の直後なら、前に空白を入れる。タグの途中で選んでも、後ろに続く文は消さず、空白で区切る。
    @Test func insertionAddsLeadingSpaceAfterJapanese() throws {
        let (text, _) = split("今日は#ね|こだ")
        let token = try #require(token("今日は#ね|こだ"))
        #expect(token.query == "ね")
        let insertion = CompletionTokenizer.insertion(of: "#ねこ", replacing: token, in: text)
        #expect(insertion.text == " #ねこ ")
        #expect(insertion.range == 3 ..< 5)
    }

    @Test func insertionReplacesClosingColon() throws {
        let (text, _) = split(":bl|ob:です")
        let token = try #require(token(":bl|ob:です"))
        let insertion = CompletionTokenizer.insertion(of: ":blobcat:", replacing: token, in: text)
        #expect(insertion.range == 0 ..< 6)
        #expect(insertion.text == ":blobcat: ")
    }
}
