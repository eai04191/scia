#if DEBUG
import SciaCore
import Testing
@testable import Scia

struct DummyAnimatedEmojisTests {
    /// どの投稿にも、重ならない8種類の絵文字を入れ、本文には入れた絵文字のショートコードを書く。
    @Test func eachPostHasDistinctEmojisWrittenInBody() {
        for number in 0..<DummyAnimatedEmojis.postCount {
            let content = DummyAnimatedEmojis.content(number: number)

            #expect(Set(content.emojis.map(\.url)).count == DummyAnimatedEmojis.emojisPerPost)
            #expect(content.emojis.allSatisfy { content.html.contains(":\($0.shortcode):") })
        }
    }

    /// 投稿をまたいで、40種類をすべて使う。
    @Test func postsUseEveryEmoji() {
        let urls = (0..<DummyAnimatedEmojis.postCount).flatMap { DummyAnimatedEmojis.content(number: $0).emojis.map(\.url) }

        #expect(Set(urls).count == 40)
    }
}
#endif
