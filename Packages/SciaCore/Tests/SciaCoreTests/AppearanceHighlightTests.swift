import CoreGraphics
import SciaCore
import Testing

/// 「投稿の見た目」の項目が、プレビューのどの部品を示すかを確かめる。
struct AppearanceHighlightTests {
    /// 投稿は本文の下に並べ、引用とXの投稿だけを本文の右に出すとき、「右に並べるときの大きさ」は、大きさの効かない投稿のメディアではなく、囲みの右のメディアを示す。
    @Test func besideSideHighlightsEmbedMediaWhenOnlyEmbedsAreBeside() throws {
        let postMedia = CGRect(x: 0, y: 0, width: 300, height: 200)
        let embedMedia = CGRect(x: 240, y: 40, width: 64, height: 64)
        let rows: [AppearancePreviewFrames] = [[.media: [postMedia]], [.xPostBesideMedia: [embedMedia]]]

        let found = try #require(AppearanceHighlight(AppearanceCatalog.mediaBesideSide)?.locate(in: rows))

        #expect(found.row == 1)
        #expect(found.rects == [embedMedia])
    }

    /// 投稿を本文の右に出していれば、投稿の右のメディアを先に示す。
    @Test func besideSideHighlightsPostMediaFirst() throws {
        let postMedia = CGRect(x: 300, y: 10, width: 64, height: 64)
        let embedMedia = CGRect(x: 240, y: 40, width: 64, height: 64)
        let rows: [AppearancePreviewFrames] = [[.besideMedia: [postMedia]], [.xPostBesideMedia: [embedMedia]]]

        let found = try #require(AppearanceHighlight(AppearanceCatalog.mediaBesideSide)?.locate(in: rows))

        #expect(found.row == 0)
    }
}
