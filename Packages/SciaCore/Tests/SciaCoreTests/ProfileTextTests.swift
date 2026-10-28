import Foundation
import Testing
@testable import SciaCore

struct ProfileTextTests {
    private func emoji(_ shortcode: String, file: String? = nil) -> CustomEmoji {
        let name = file ?? shortcode
        return CustomEmoji(
            shortcode: shortcode,
            url: URL(string: "https://example.com/emoji/\(name).gif") ?? URL(fileURLWithPath: "/"),
            staticUrl: URL(string: "https://example.com/emoji/\(name).png") ?? URL(fileURLWithPath: "/")
        )
    }

    private func account(displayName: String = "", note: String = "", fields: [Account.Field] = [], emojis: [CustomEmoji] = []) -> Account {
        Account(id: "1", username: "alice", acct: "alice", displayName: displayName, avatar: nil, note: note, fields: fields, emojis: emojis)
    }

    /// 自己紹介は、書式とリンクを落とした文字を段落ごとに改行でつなぎ、絵文字は`:shortcode:`のまま残す。
    @Test func noteTextDropsMarkupAndKeepsShortcodes() {
        let alice = account(
            note: #"<p>Hello <strong>world</strong> :blobcat:</p><p><a href="https://example.com/">example.com</a></p>"#,
            emojis: [emoji("blobcat")]
        )

        #expect(alice.profileText(.note)?.text == "Hello world :blobcat:\nexample.com")
        #expect(alice.profileText(.note)?.emojis.map(\.shortcode) == ["blobcat"])
    }

    /// アカウントの絵文字には表示名や補足情報の絵文字も入るため、長押しした文章に描いているものだけを、出てくる順に1度ずつ出す。
    @Test func emojisAreLimitedToThePartInOrderOfAppearance() {
        let alice = account(
            displayName: "Alice :name: :name:",
            note: "<p>:second: :first: :second:</p>",
            emojis: [emoji("first"), emoji("second"), emoji("name")]
        )

        #expect(alice.profileText(.displayName)?.emojis.map(\.shortcode) == ["name"])
        #expect(alice.profileText(.note)?.emojis.map(\.shortcode) == ["second", "first"])
    }

    /// ショートコードが違っても、同じ画像の絵文字は1度だけ数える。
    @Test func emojisWithTheSameImageAreCountedOnce() {
        let alice = account(note: "<p>:a: :b:</p>", emojis: [emoji("a", file: "same"), emoji("b", file: "same")])

        #expect(alice.profileText(.note)?.emojis.map(\.shortcode) == ["a"])
    }

    /// 補足情報は、内容をコピーと翻訳に、ラベルをラベルのコピーに渡し、絵文字はラベルと内容の両方から集める。
    @Test func fieldTextIsTheValueAndEmojisIncludeTheLabel() {
        let alice = account(
            fields: [
                Account.Field(name: "Web", value: "https://example.com"),
                Account.Field(name: ":label: Site", value: #"<a href="https://example.org/">example.org</a> :value:"#),
            ],
            emojis: [emoji("label"), emoji("value")]
        )

        #expect(alice.profileText(.field(1))?.text == "example.org :value:")
        #expect(alice.profileText(.field(1))?.label == ":label: Site")
        #expect(alice.profileText(.field(1))?.emojis.map(\.shortcode) == ["label", "value"])
        #expect(alice.profileText(.field(2)) == nil)
    }

    /// ラベルは補足情報にだけあり、空白だけならラベルのコピーを出さない。
    @Test func labelIsOnlyForFieldsWithText() {
        let alice = account(displayName: "Alice", note: "<p>Hi</p>", fields: [Account.Field(name: " ", value: "Hi")])

        #expect(alice.profileText(.displayName)?.label == nil)
        #expect(alice.profileText(.note)?.label == nil)
        #expect(alice.profileText(.field(0))?.label == nil)
    }

    /// 表示名が空ならユーザー名を描いているので、ユーザー名を渡す。
    @Test func emptyDisplayNameFallsBackToUsername() {
        #expect(account().profileText(.displayName)?.text == "alice")
    }

    /// メモは書いたままの文字を渡し、ラベルもカスタム絵文字もない。`<`や`:shortcode:`もそのまま残す。
    @Test func privateNoteIsPlainTextWithoutLabelOrEmojis() {
        let note = ProfileText.privateNote("前に会った <b>人</b>\n:blobcat: 好き")

        #expect(note.text == "前に会った <b>人</b>\n:blobcat: 好き")
        #expect(note.label == nil)
        #expect(note.emojis.isEmpty)
        #expect(ProfileText.privateNote(" \n").text == nil)
    }

    /// 空白だけの文章では、コピーと翻訳を出さない。
    @Test func whitespaceOnlyTextIsNil() {
        #expect(account(note: "<p> </p>").profileText(.note)?.text == nil)
        #expect(account(note: "").profileText(.note)?.text == nil)
    }
}
