public import Foundation

/// APIの応答の本文を、人が読むための文字にする。投稿のメニューの「APIの応答」で出す。
public struct APIResponseText: Equatable, Sendable {
    /// 色分けする字句の種類。
    public enum Kind: Equatable, Sendable {
        case key
        case string
        case number
        case bool
        case null
    }

    /// 色分けする字句。`range`は`text`のUTF-16での位置で、`NSAttributedString`の範囲にそのまま使える。
    public struct Token: Equatable, Sendable {
        public let kind: Kind
        public let range: Range<Int>

        public init(kind: Kind, range: Range<Int>) {
            self.kind = kind
            self.range = range
        }
    }

    /// UTF-8ではない応答。
    public struct NotUTF8: Error {}

    public let text: String
    public let tokens: [Token]

    /// 応答の文字を字句に分けて、字下げし直す。サーバーが付けた値をそのまま確かめられるよう、キーの並び、数、true、false、nullは応答の文字のまま出す。
    /// 文字列だけは、中のエスケープ（Railsが`<`を`<`と書くものなど）を読める文字に戻す。投稿の本文のHTMLが読めなくなるため。
    /// 値に読み直してから書くと、並びが失われ、数の書き方（`1.0`や`-0`）も変わるため、`JSONSerialization`は形を確かめるためだけに使う。
    /// JSONとして読めなければ投げる。
    public static func formatted(_ data: Data) throws -> APIResponseText {
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        // `JSONSerialization`はUTF-16とUTF-32も読むが、字句に分けるのはUTF-8だけ。読めたJSONのUTF-8には、0x00（制御文字は文字列の中でもエスケープが要る）も、
        // 0xFEと0xFF（UTF-8に現れない）もないため、どれかがあればほかの符号化として投げる。Mastodonの応答はUTF-8なので、ほかの符号化は出さない。
        guard !data.contains(where: { $0 == 0x00 || $0 >= 0xFE }) else { throw NotUTF8() }
        // 先頭のBOMは`JSONSerialization`が読み飛ばすので、こちらでも外す。UTF-8のほかの符号化はMastodonが返さないため扱わない。
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        var writer = Writer(bytes: data.starts(with: bom) ? Array(data.dropFirst(bom.count)) : Array(data))
        try writer.run()
        return APIResponseText(text: writer.text, tokens: writer.tokens)
    }

    /// 形を確かめ済みのJSONを、1文字ずつ進めて書き直す。入れ子を関数の呼び直しでたどらないので、深いJSONでもスタックを使わない。
    private struct Writer {
        let bytes: [UInt8]
        var position = 0
        var text = ""
        var tokens: [Token] = []
        /// `text`のUTF-16での長さ。追記のたびに数え直さないよう、足した分を数える。
        private var length = 0
        private var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func run() throws {
            while let byte = nextNonWhitespace() {
                switch byte {
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    position += 1
                    let close = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                    if nextNonWhitespace() == close {
                        // 中身が空なら`{}`や`[]`と1行で書く。
                        position += 1
                        append(String(decoding: [byte, close], as: UTF8.self))
                    } else {
                        depth += 1
                        append(String(decoding: [byte], as: UTF8.self) + "\n" + indent)
                    }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    position += 1
                    depth -= 1
                    append("\n" + indent + String(decoding: [byte], as: UTF8.self))
                case UInt8(ascii: ","):
                    position += 1
                    // `JSONSerialization`が許す末尾のカンマは、出さずに閉じる。出すと空白だけの行が残る。
                    if let next = nextNonWhitespace(), next == UInt8(ascii: "}") || next == UInt8(ascii: "]") { continue }
                    append(",\n" + indent)
                case UInt8(ascii: ":"):
                    position += 1
                    append(": ")
                case UInt8(ascii: "\""):
                    let string = try readString()
                    append(Self.quoted(string), as: nextNonWhitespace() == UInt8(ascii: ":") ? .key : .string)
                default:
                    let literal = readLiteral()
                    let kind: Kind = switch literal {
                    case "true", "false": .bool
                    case "null": .null
                    default: .number
                    }
                    append(literal, as: kind)
                }
            }
        }

        private var indent: String { String(repeating: "  ", count: depth) }

        /// 空白を読み飛ばし、次の文字を返す。進めるのは空白の分だけ。
        private mutating func nextNonWhitespace() -> UInt8? {
            while position < bytes.count, Self.whitespace.contains(bytes[position]) {
                position += 1
            }
            return position < bytes.count ? bytes[position] : nil
        }

        /// 引用符で囲んだ文字列を読み、エスケープを戻した文字にする。エスケープの戻し方（サロゲートペアなど）は`JSONSerialization`に任せる。
        private mutating func readString() throws -> String {
            let start = position
            position += 1
            while bytes[position] != UInt8(ascii: "\"") {
                // エスケープの次の文字は、引用符でも文字列の終わりにしない。
                position += bytes[position] == UInt8(ascii: "\\") ? 2 : 1
            }
            position += 1
            let raw = Data(bytes[start..<position])
            guard let string = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return string
        }

        /// 数やtrue、false、nullを、区切りの文字の手前まで、応答の文字のまま読む。
        private mutating func readLiteral() -> String {
            let start = position
            while position < bytes.count, !Self.whitespace.contains(bytes[position]), !Self.structural.contains(bytes[position]) {
                position += 1
            }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        private static let structural: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: ":")]

        private mutating func append(_ string: String, as kind: Kind? = nil) {
            let count = string.utf16.count
            if let kind {
                tokens.append(Token(kind: kind, range: length..<(length + count)))
            }
            text += string
            length += count
        }

        /// JSONの文字列にする。読みやすさのため、`/`と日本語などはエスケープしない。
        private static func quoted(_ string: String) -> String {
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
    }
}
