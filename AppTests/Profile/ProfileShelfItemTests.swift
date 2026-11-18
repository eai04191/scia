import Foundation
import UIKit
import SciaCore
import SciaTesting
import Testing
@testable import Scia

/// 固定された投稿のカードの添付ファイルの出し方と読み上げを確かめる。
@Suite(.scratch, .failureState)
@MainActor
struct ProfileShelfItemTests {
    private static let blurhash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let filtering = StatusFiltering(context: .account, myAccountID: nil)

    private func item(
        media: [MediaAttachment] = [Self.image],
        spoilerText: String = "",
        sensitive: Bool = false,
        filter: FilterResult.Action? = nil,
        settings: AppSettings = .isolated(),
        choice: (inout MediaCovers, Status) -> Void = { _, _ in }
    ) throws -> ProfileShelfItem {
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
        return ProfileShelfItem(status: status, verdict: Self.filtering.verdict(for: status, now: Self.now), covers: covers, settings: settings)
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

    @Test func 閲覧注意でない添付ファイルはぼかさずに重ねて出す() throws {
        let media = try #require(try item().media)
        #expect(media.cover == nil)
        #expect(media.isStacked)
    }

    @Test func 本文の下に大きく並べる設定でも重ねて出す() throws {
        let settings = AppSettings.isolated()
        settings.appearance.mediaArrangement = .belowBody
        #expect(try item(settings: settings).media?.isStacked == true)
    }

    @Test func 閲覧注意の添付ファイルはぼかす() throws {
        #expect(try item(sensitive: true).media?.cover == .sensitive)
    }

    @Test func ぼかすフィルターの添付ファイルはぼかす() throws {
        #expect(try item(filter: .blur).media?.cover == .filtered(["フィルター"]))
    }

    @Test func 使う人が隠した添付ファイルはぼかす() throws {
        #expect(try item(choice: { covers, status in covers.hide(status) }).media?.cover == .hidden)
    }

    @Test func 使う人がぼかしを外した閲覧注意の添付ファイルはぼかさない() throws {
        let media = try #require(try item(sensitive: true, choice: { covers, status in covers.reveal(status) }).media)
        #expect(media.cover == nil)
    }

    @Test func 注意書きのある投稿には出さない() throws {
        #expect(try item(spoilerText: "注意書き", sensitive: true).media == nil)
    }

    @Test func フィルターの警告の投稿には出さない() throws {
        #expect(try item(filter: .warn).media == nil)
    }

    @Test func 添付ファイルのない投稿には出さない() throws {
        #expect(try item(media: [], sensitive: true).media == nil)
    }

    @Test func 添付ファイルの数を読み上げる() throws {
        #expect(try item().spokenAttachmentCount == 1)
    }

    @Test func 注意書きのある投稿では添付ファイルの数を読み上げない() throws {
        #expect(try item(spoilerText: "注意書き").spokenAttachmentCount == 0)
    }

    @Test func フィルターの警告の投稿では添付ファイルの数を読み上げない() throws {
        #expect(try item(filter: .warn).spokenAttachmentCount == 0)
    }

    @Test func 右に並べる大きさを上限にしても狭い棚で本文の幅を残す() throws {
        let settings = AppSettings.isolated()
        settings.setValue(AppearanceCatalog.mediaBesideSide.range.upperBound, for: AppearanceCatalog.mediaBesideSide)
        let shelf = ProfilePinnedShelfView(emojiImages: AppDependencies.emojiImages, mediaImages: AppDependencies.mediaImages, settings: settings)
        shelf.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        shelf.setItems([try item(settings: settings)], glyphLanguage: "ja")
        shelf.layoutIfNeeded()
        let body = try #require(shelf.firstSubview(of: EmojiLabel.self))
        #expect(body.bounds.width >= 80)
    }
}

private extension UIView {
    func firstSubview<View: UIView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let view = subview as? View { return view }
            if let view = subview.firstSubview(of: type) { return view }
        }
        return nil
    }
}
