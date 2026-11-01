import Foundation
import SciaCore
import Testing

struct APIResponseTextTests {
    private func tokens(_ formatted: APIResponseText) -> [String] {
        let utf16 = Array(formatted.text.utf16)
        return formatted.tokens.map { token in
            "\(token.kind):\(String(decoding: utf16[token.range], as: UTF16.self))"
        }
    }

    /// キーはサーバーが返した並びのまま、1段2文字で字下げする。空の配列と辞書は1行にする。
    @Test func keepsKeyOrderAndIndents() throws {
        let data = Data(#"{"url":"https://example.social/@alice/1","language":"zh","tags":[ ],"poll":{},"emojis":[1,{"a":2}]}"#.utf8)
        #expect(try APIResponseText.formatted(data).text == """
        {
          "url": "https://example.social/@alice/1",
          "language": "zh",
          "tags": [],
          "poll": {},
          "emojis": [
            1,
            {
              "a": 2
            }
          ]
        }
        """)
    }

    /// 数とtrue、false、nullは応答の文字のまま出す。読み直すと`1.0`は`1`、`-0`は`0`になってしまう。同じキーが2つあっても両方出す。
    @Test func keepsLiteralsAsWritten() throws {
        let data = Data(#"[1.0,-0,1E-7,0.30000000000000004,12345678901234567890,true,null,{"a":1,"a":2}]"#.utf8)
        let text = try APIResponseText.formatted(data).text
        #expect(text == "[\n  1.0,\n  -0,\n  1E-7,\n  0.30000000000000004,\n  12345678901234567890,\n  true,\n  null,\n  {\n    \"a\": 1,\n    \"a\": 2\n  }\n]")
    }

    /// 文字列の中のエスケープは読める文字に戻す。`/`と日本語はエスケープせず、改行などの制御文字は読み直せる形でエスケープし直す。
    @Test func unescapesStrings() throws {
        let data = Data(#"{"content":"<p>札幌 😀 \"q\" \\ https:\/\/x\/ 1\n2\u0001"}"#.utf8)
        let text = try APIResponseText.formatted(data).text
        #expect(text == #"{"# + "\n" + #"  "content": "<p>札幌 😀 \"q\" \\ https://x/ 1\n2\u0001""# + "\n}")
        let reread = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        #expect(reread == ["content": "<p>札幌 😀 \"q\" \\ https://x/ 1\n2\u{1}"])
    }

    /// 字句の範囲は、キー、文字列、数、真偽値、nullを分けて指す。範囲はUTF-16で数えるので、絵文字のあとでもずれない。
    /// 値の文字列のあとに`:`はないので、キーと値は区切りの`:`で見分ける。
    @Test func recordsTokenRanges() throws {
        let data = Data(#"{"a😀" : "😀\"x","b":1.5,"c":true,"d":null,"e":["k"]}"#.utf8)
        #expect(tokens(try APIResponseText.formatted(data)) == [
            #"key:"a😀""#, #"string:"😀\"x""#,
            #"key:"b""#, "number:1.5",
            #"key:"c""#, "bool:true",
            #"key:"d""#, "null:null",
            #"key:"e""#, #"string:"k""#,
        ])
    }

    /// 入れ子を関数の呼び直しでたどらないので、`JSONSerialization`が読める深さなら書ける。
    @Test func formatsDeepNesting() throws {
        let depth = 500
        let data = Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
        #expect(try APIResponseText.formatted(data).tokens.count == 1)
    }

    /// トップレベルが文字列や数だけでも出す。先頭のBOMは外す。
    @Test func formatsFragmentsAndSkipsBOM() throws {
        #expect(try APIResponseText.formatted(Data("5".utf8)).text == "5")
        #expect(try APIResponseText.formatted(Data([0xEF, 0xBB, 0xBF] + Array(#" {"a":1} "#.utf8))).text == "{\n  \"a\": 1\n}")
    }

    /// `JSONSerialization`はUTF-16とUTF-32も読むが、字句に分けるのはUTF-8だけなので、ほかの符号化は書かずに投げる。
    @Test(arguments: [String.Encoding.utf16BigEndian, .utf16LittleEndian, .utf16, .utf32BigEndian])
    func throwsOnNonUTF8(_ encoding: String.Encoding) throws {
        let data = try #require("[1,{}]".data(using: encoding))
        #expect(throws: APIResponseText.NotUTF8.self) { try APIResponseText.formatted(data) }
    }

    /// `JSONSerialization`が許す末尾のカンマは、出さずに閉じる。
    @Test func dropsTrailingCommas() throws {
        #expect(try APIResponseText.formatted(Data(#"[1,{"a":1,},]"#.utf8)).text == "[\n  1,\n  {\n    \"a\": 1\n  }\n]")
    }

    @Test func throwsOnBrokenJSON() {
        #expect(throws: (any Error).self) { try APIResponseText.formatted(Data("<html>".utf8)) }
        #expect(throws: (any Error).self) { try APIResponseText.formatted(Data()) }
    }
}
