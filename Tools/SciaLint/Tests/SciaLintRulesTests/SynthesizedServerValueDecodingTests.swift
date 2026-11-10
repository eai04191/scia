@testable import SciaLintRules
import Testing

@Suite struct SynthesizedServerValueDecodingTests {
    private func violations(_ source: String, path: String = "Packages/SciaCore/Sources/SciaCore/Models/Foo.swift") -> Int {
        Linter.lint(source: source, path: path, rules: [.synthesizedServerValueDecoding]).count
    }

    @Test(arguments: [
        "struct Tweet: Decodable { let url: URL }",
        "struct Item: Decodable { let width: Int? }",
        "struct Facet: Decodable { let indices: [Int] }",
        "struct Counts: Decodable { let byName: [String: Int] }",
        "struct Tweet: Codable { let url: Foundation.URL }",
        "public struct Tweet: Hashable, Decodable, Sendable { public let url: URL }",
        "struct Tweet: Swift.Decodable { let url: URL }",
        "final class Tweet: Decodable { let url: URL }",
        "struct Tweet: Decodable { var count: Int = 0 }",
        "struct Tweet: Decodable { var count: Int { didSet {} } }",
        // 関数の中の型と、入れ子の型
        "func load() { struct Instance: Decodable { struct URLs: Decodable { let streaming: URL }\nlet urls: URLs } }",
        // 適合を同じファイルのextensionに書いても、コンパイラーが読み方を作る
        "struct Tweet { let url: URL }\nextension Tweet: Decodable {}",
        // ほかの型のextensionにinit(from:)があっても、この型の読み方は書いていない
        "struct Tweet: Decodable { let url: URL }\nextension Other { init(from decoder: any Decoder) throws {} }",
        // CodingKeysに書いたプロパティは読まれる
        "struct Tweet: Decodable { let url: URL\nlet id: String\nenum CodingKeys: String, CodingKey { case id, url } }",
    ])
    func flagsSynthesizedDecoding(_ source: String) {
        #expect(violations(source) == 1)
    }

    @Test func flagsEachProperty() {
        #expect(violations("struct Item: Decodable { let url: URL\nlet width: Int?\nlet height: Int?\nlet type: String }") == 3)
        #expect(violations("struct Item: Decodable { let width, height: Int? }") == 1)
        #expect(violations("struct Item: Decodable { let width: Int?, height: Int? }") == 2)
    }

    @Test(arguments: [
        // 手書きのinit(from:)の中は、server_value_without_checkが調べる
        "struct Tweet: Decodable { let url: URL\ninit(from decoder: any Decoder) throws { url = try decoder.container(keyedBy: K.self).decodeRequiredURL(.destination, forKey: .url) } }",
        "struct Tweet: Decodable { let url: URL }\nextension Tweet { init(from decoder: any Decoder) throws { fatalError() } }",
        "struct Outer { struct Item: Decodable { let width: Int? } }\nextension Outer.Item { init(from decoder: any Decoder) throws { fatalError() } }",
        // Decodableでない型
        "struct Tweet: Hashable, Sendable { let url: URL }",
        "struct Request: Encodable { let limit: Int }",
        // 整数もURLも持たない型
        "struct Tweet: Decodable { let id: String\nlet text: RichText\nlet limit: ServerLimit? }",
        // 読まれないプロパティ
        "struct Tweet: Decodable { let id: String\nstatic let pageSize: Int = 20 }",
        "struct Tweet: Decodable { let id: String\nlet pageSize: Int = 20 }",
        "struct Tweet: Decodable { let id: String\nvar count: Int { 0 } }",
        "struct Tweet: Decodable { let id: String\nvar count: Int { get { 0 } set {} } }",
        "struct Tweet: Decodable { let id: String\nvar url: URL?\nenum CodingKeys: String, CodingKey { case id } }",
        // 生の値で読むenum
        "enum Code: Int, Decodable { case ok = 200 }",
        "// struct Tweet: Decodable { let url: URL }",
    ])
    func allowsCheckedOrUndecodedValues(_ source: String) {
        #expect(violations(source) == 0)
    }

    @Test func allowsSuppressionWithReason() {
        let source = """
        struct Facet: Decodable {
            // scialint:disable:next synthesized_server_value_decoding
            let indices: [Int]
        }
        """
        #expect(violations(source) == 0)
    }

    @Test(arguments: [
        "Packages/SciaCore/Sources/SciaCore/Models/Foo.swift",
        "Packages/SciaCore/Sources/SciaCore/Networking/MastodonClient.swift",
        "Packages/SciaCore/Sources/SciaCore/Streaming/StreamingEvent.swift",
        "Packages/SciaCore/Sources/SciaCore/XPosts/XPost.swift",
        "Packages/SciaCore/Sources/SciaCore/Models/Sub/Foo.swift",
    ])
    func checksServerValueFolders(_ path: String) {
        #expect(violations("struct Tweet: Decodable { let url: URL }", path: path) == 1)
    }

    @Test(arguments: [
        "Packages/SciaCore/Sources/SciaCore/Tuning/TuningStore.swift",
        "Packages/SciaCore/Sources/SciaCore/ServerValues.swift",
        "Packages/SciaCore/Tests/SciaCoreTests/Models/Foo.swift",
        "App/Sources/Models/Foo.swift",
    ])
    func ignoresOtherFolders(_ path: String) {
        #expect(violations("struct Tweet: Decodable { let url: URL }", path: path) == 0)
    }
}
