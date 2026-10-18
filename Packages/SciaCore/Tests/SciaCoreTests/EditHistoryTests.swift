import Foundation
import Testing
@testable import SciaCore

struct RichTextDiffTests {
    private func diff(_ old: String, _ new: String, minimumUnchangedRatio: Double = 0) -> RichTextDiff {
        RichTextDiff(old: .html(old, emojis: []), new: .html(new, emojis: []), minimumUnchangedRatio: minimumUnchangedRatio)
    }

    /// `[-消えた-]{+足された+}`の形で書く。段落は`¶`でつなぐ。
    private func marked(_ diff: RichTextDiff) -> String {
        diff.blocks.map { block in
            block.pieces.map { piece in
                let text = switch piece.inline {
                case .text(let string, _), .link(let string, _, _): string
                case .emoji(let emoji): ":\(emoji.shortcode):"
                case .lineBreak: "\n"
                }
                return switch piece.change {
                case .unchanged: text
                case .inserted: "{+\(text)+}"
                case .removed: "[-\(text)-]"
                }
            }.joined()
        }.joined(separator: "¶")
    }

    @Test(arguments: [
        // 数字は1つの単語として入れ替える。文字単位だと「1」だけが残る。
        ("明日の勉強会は14時からです。場所は会議室Bです", "明日の勉強会は15時からです。場所はいつもの会議室Bです",
         "明日の勉強会は[-14-]{+15+}時からです。場所は{+いつもの+}会議室Bです"),
        // 文字単位だと「く」を共有して「[-すご-]{+めちゃ+}く{+ちゃ+}」と割れる。
        ("新しいMacBookを買った！すごく速い", "新しいMacBook Proを買った！めちゃくちゃ速い",
         "新しいMacBook{+ Pro+}を買った！[-すごく-]{+めちゃくちゃ+}速い"),
        ("typo: recieve the message", "typo: receive the message", "typo: [-recieve-]{+receive+} the message"),
    ])
    func comparesWords(old: String, new: String, expected: String) {
        #expect(marked(diff("<p>\(old)</p>", "<p>\(new)</p>")) == expected)
    }

    @Test func sameTextHasNoChanges() {
        let result = diff("<p>同じ本文</p>", "<p>同じ本文</p>")
        #expect(!result.hasChanges)
        #expect(marked(result) == "同じ本文")
    }

    /// 消えた単語と足された単語が交互に並ぶと、どれがどれに置き換わったか読めない。
    @Test func removedComesBeforeInserted() {
        #expect(marked(diff("<p>a b c</p>", "<p>x y z</p>")) == "[-a b c-]{+x y z+}")
        // 空白より長い一致はまとめない。
        #expect(marked(diff("<p>来週の水曜日</p>", "<p>再来週の金曜日</p>")) == "[-来週-]{+再来週+}の[-水曜-]{+金曜+}日")
    }

    /// リンクは文字が同じでも行き先が変われば置き換え、単語に分けない。
    @Test func linkIsComparedWhole() {
        let result = diff(
            #"<p>見て <a href="https://a.example/one">https://a.example/one</a></p>"#,
            #"<p>見て <a href="https://a.example/two">https://a.example/two</a></p>"#
        )
        #expect(marked(result) == "見て [-https://a.example/one-]{+https://a.example/two+}")
    }

    /// 消えた段落の文字が、前の段落に続けて並ばないよう、消えた改行を挟む。
    @Test func removedParagraphKeepsItsBreak() {
        #expect(marked(diff("<p>一段落目</p><p>消す段落</p>", "<p>一段落目</p>")) == "一段落目[-\n-][-消す段落-]")
    }

    @Test func insertedParagraphStartsNewBlock() {
        #expect(marked(diff("<p>一段落目</p>", "<p>一段落目</p><p>足した段落</p>")) == "一段落目¶{+足した段落+}")
    }

    /// 文字を変えずに段落を分けただけの編集も、変更として残す。
    @Test func splittingParagraphIsAChange() {
        let result = diff(
            #"<p><a href="https://a.example/one">one</a><a href="https://a.example/two">two</a></p>"#,
            #"<p><a href="https://a.example/one">one</a></p><p><a href="https://a.example/two">two</a></p>"#
        )
        #expect(result.hasChanges)
        #expect(result.blocks.map(\.breakChange) == [.unchanged, .inserted])
    }

    /// 最初の段落の形だけを変えた編集（引用にするなど）も、変更として残す。
    @Test func changingFirstBlockLayoutIsAChange() {
        let result = diff("<p>引用する文</p>", "<blockquote><p>引用する文</p></blockquote>")
        #expect(result.hasChanges)
        #expect(result.blocks.map(\.breakChange) == [.inserted])
        #expect(result.blocks.map(\.quoteLevel) == [1])
    }

    /// パーサーは書式の違う部分ごとにリンクを分けるが、1つのリンクとして比べる。
    @Test func styledLinkIsComparedWhole() {
        let result = diff(
            #"<p><a href="https://example.org/">read <strong>old</strong></a></p>"#,
            #"<p><a href="https://example.org/">read <strong>new</strong></a></p>"#
        )
        // 書式の違う部分は別の部品のまま、どれも変わったものとして並ぶ。
        #expect(marked(result) == "[-read -][-old-]{+read +}{+new+}")
    }

    /// 単語に分けても、文字が欠けたり増えたりしない。
    @Test(arguments: [nil, "ja", "en", "ar", "zh", "th"] as [String?])
    func tokenizerKeepsEveryCharacter(language: String?) {
        for text in ["hello, world!", "猫と犬", "👨‍👩‍👧‍👦🇯🇵e\u{301}\n ", "ภาษาไทย", "中文测试", "مرحبا بالعالم", "", "\r\n\t"] {
            #expect(WordTokenizer(language: language).words(in: text).joined() == text)
        }
    }

    /// 段落を足して消したまとまりでは、消えた改行を挟まない。挟むと改行が2つ並ぶ。
    @Test func replacedParagraphDoesNotDoubleBreak() {
        #expect(marked(diff("<p>前</p><p>古い段落</p>", "<p>前</p><p>新しい段落</p>")) == "前¶[-古い-]{+新しい+}段落")
    }

    /// 大半を書き直した版は、前の版をまるごと消し、新しい版をまるごと足す。
    @Test func mostlyRewrittenTextIsReplacedWhole() {
        let result = diff(
            "<p>リリースは来週の水曜日を予定しています</p>",
            "<p>延期します。詳しくは後で</p>",
            minimumUnchangedRatio: 0.3
        )
        #expect(marked(result) == "[-リリースは来週の水曜日を予定しています-]¶{+延期します。詳しくは後で+}")
    }

    @Test func smallEditIsNotTreatedAsRewrite() {
        let result = diff("<p>明日の勉強会は14時からです</p>", "<p>明日の勉強会は15時からです</p>", minimumUnchangedRatio: 0.3)
        #expect(marked(result) == "明日の勉強会は[-14-]{+15+}時からです")
    }
}

struct StatusEditHistoryTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    private func history() async throws -> StatusEditHistory {
        let revisions = try await (try makeClient(StubTransport([try .fixture("status_history")])))
            .statusHistory("113000000000000001")
        return StatusEditHistory(revisions: revisions, mentions: [], tags: [], language: "ja", minimumUnchangedRatio: 0.3)
    }

    @Test func readsHistory() async throws {
        let transport = StubTransport([try .fixture("status_history")])

        let revisions = try await (try makeClient(transport))
            .statusHistory("113000000000000001")

        #expect(await transport.requests.first?.url?.path() == "/api/v1/statuses/113000000000000001/history")
        #expect(revisions.count == 4)
        #expect(revisions[1].mediaAttachments.first?.description == "会議室Bの入口")
        #expect(revisions[2].spoilerText == "勉強会")
        #expect(revisions[2].sensitive)
    }

    @Test func entriesAreNewestFirst() async throws {
        let entries = try await history().entries

        #expect(entries.map(\.editNumber) == [3, 2, 1, 0])
        #expect(entries.last?.isOriginal == true)
        #expect(entries.last?.changes == [])
        #expect(entries.last?.body.hasChanges == false)
    }

    @Test func descriptionOnlyEdit() async throws {
        let entry = try await history().entries[2]

        #expect(!entry.body.hasChanges)
        #expect(entry.spoiler == nil)
        guard case .mediaDescriptionChanged(let attachment, let description) = try #require(entry.changes.first) else {
            Issue.record("代替テキストの変更がない: \(entry.changes)")
            return
        }
        #expect(attachment.id == "201")
        #expect(description.hasChanges)
        #expect(entry.changes.count == 1)
    }

    @Test func textSpoilerSensitiveAndMediaEdit() async throws {
        let entry = try await history().entries[1]

        #expect(entry.body.hasChanges)
        #expect(entry.spoiler?.blocks.flatMap(\.pieces) == [RichTextDiff.Piece(.text("勉強会", []), .inserted)])
        #expect(entry.changes.count == 2)
        #expect(entry.changes.first == .sensitiveAdded)
        guard case .mediaAdded(let attachment) = entry.changes.last else {
            Issue.record("添付ファイルの追加がない: \(entry.changes)")
            return
        }
        #expect(attachment.id == "202")
    }

    @Test func removingSpoilerAndReordering() async throws {
        let entry = try await history().entries[0]

        #expect(!entry.body.hasChanges)
        #expect(entry.spoiler?.blocks.flatMap(\.pieces) == [RichTextDiff.Piece(.text("勉強会", []), .removed)])
        #expect(entry.changes == [.sensitiveRemoved, .mediaReordered])
    }

    @Test func removedMediaIsListed() throws {
        let account = try MastodonDecoder.make().decode(Account.self, from: Data(Self.account.utf8))
        let first = MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil)
        let second = MediaAttachment(id: "2", type: .image, url: nil, previewUrl: nil)
        let revisions = [
            StatusRevision(content: "<p>a</p>", createdAt: .now, account: account, mediaAttachments: [first, second]),
            StatusRevision(content: "<p>a</p>", createdAt: .now, account: account, mediaAttachments: [second]),
        ]

        let entry = StatusEditHistory(revisions: revisions, mentions: [], tags: [], language: nil, minimumUnchangedRatio: 0.3).entries[0]

        // 残った1枚は前と同じ順なので、並べ替えにはしない。
        #expect(entry.changes == [.mediaRemoved(first)])
    }

    @Test func pollOptionChanges() throws {
        let account = try MastodonDecoder.make().decode(Account.self, from: Data(Self.account.utf8))
        let revisions = [
            StatusRevision(content: "<p>どれ？</p>", createdAt: .now, account: account),
            StatusRevision(content: "<p>どれ？</p>", createdAt: .now, account: account, pollOptions: ["猫", "犬"]),
            StatusRevision(content: "<p>どれ？</p>", createdAt: .now, account: account, pollOptions: ["猫", "鳥"]),
        ]

        let entries = StatusEditHistory(revisions: revisions, mentions: [], tags: [], language: nil, minimumUnchangedRatio: 0.3).entries

        #expect(entries[1].changes == [.pollOptions([.init("猫", .inserted), .init("犬", .inserted)])])
        #expect(entries[0].changes == [.pollOptions([.init("猫", .unchanged), .init("犬", .removed), .init("鳥", .inserted)])])
    }

    private static let account = #"{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
}
