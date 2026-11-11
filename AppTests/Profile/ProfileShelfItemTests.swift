import Foundation
import SciaCore
import SciaTesting
import Testing
@testable import Scia

/// 固定された投稿のカードのサムネイルの出し方を確かめる。
@Suite(.failureState)
struct ProfileShelfItemTests {
    private static let blurhash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let filtering = StatusFiltering(context: .account, myAccountID: nil)

    private func cardThumbnail(
        media: [MediaAttachment] = [Self.image],
        spoilerText: String = "",
        sensitive: Bool = false,
        filter: FilterResult.Action? = nil,
        choice: (inout MediaCovers, Status) -> Void = { _, _ in }
    ) throws -> ProfileShelfItem.CardThumbnail? {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 1).first)
        let status = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: base.content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media,
            sensitive: sensitive,
            filtered: filter.map { [FilterResult(filter: FilterResult.Filter(id: "1", title: "フィルター", context: [.account], filterAction: $0))] } ?? []
        )
        var covers = MediaCovers()
        choice(&covers, status)
        return ProfileShelfItem(status: status, verdict: Self.filtering.verdict(for: status, now: Self.now), covers: covers).cardThumbnail(size: 64)
    }

    private static let image = MediaAttachment(
        id: "1",
        type: .image,
        url: URL(string: "https://files.example.social/original/1.png"),
        previewUrl: URL(string: "https://files.example.social/small/1.png"),
        description: nil,
        meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 400, height: 400)),
        blurhash: blurhash
    )

    @Test func 閲覧注意でない添付ファイルは画像を読む() throws {
        guard case .image = try cardThumbnail() else {
            Issue.record("画像を読むはず")
            return
        }
    }

    @Test func 閲覧注意の添付ファイルは画像を読まずにぼかす() throws {
        #expect(try cardThumbnail(sensitive: true) == .covered(blurhash: Self.blurhash))
    }

    @Test func ぼかすフィルターの添付ファイルは画像を読まずにぼかす() throws {
        #expect(try cardThumbnail(filter: .blur) == .covered(blurhash: Self.blurhash))
    }

    @Test func 使う人が隠した添付ファイルはぼかす() throws {
        #expect(try cardThumbnail(choice: { covers, status in covers.hide(status) }) == .covered(blurhash: Self.blurhash))
    }

    @Test func 使う人がぼかしを外した閲覧注意の添付ファイルは画像を読む() throws {
        guard case .image = try cardThumbnail(sensitive: true, choice: { covers, status in covers.reveal(status) }) else {
            Issue.record("画像を読むはず")
            return
        }
    }

    @Test func 注意書きのある投稿には出さない() throws {
        #expect(try cardThumbnail(spoilerText: "注意書き", sensitive: true) == nil)
    }

    @Test func フィルターの警告の投稿には出さない() throws {
        #expect(try cardThumbnail(filter: .warn) == nil)
    }

    @Test func 添付ファイルのない投稿には出さない() throws {
        #expect(try cardThumbnail(media: [], sensitive: true) == nil)
    }
}
