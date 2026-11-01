import Foundation
import SciaCore
import Testing

struct APIResponseTextTests {
    /// キーを名前の順に並べて字下げし、URLの`/`と日本語はエスケープせずに出す。
    @Test func formatsWithSortedKeys() throws {
        let data = Data(#"{"url":"https:\/\/example.social\/@alice\/1","language":"zh","content":"<p>札幌</p>"}"#.utf8)
        #expect(try APIResponseText.formatted(data) == """
        {
          "content" : "<p>札幌</p>",
          "language" : "zh",
          "url" : "https://example.social/@alice/1"
        }
        """)
    }

    @Test func throwsOnBrokenJSON() {
        #expect(throws: (any Error).self) { try APIResponseText.formatted(Data("<html>".utf8)) }
    }
}
