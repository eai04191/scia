import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 名前とハンドルを2段に分ける並べ方と、アイコンの下を空けない並べ方。決まりはdocs/post-header-layout.mdにある。
@Suite(.scratch)
@MainActor
struct PostHeaderLayoutTests {
    /// - Parameter displayName: 投稿した人の名前。nilなら作った投稿のまま。
    /// - Parameter media: 画像を1枚付け、本文を空にする。
    private func status(displayName: String? = nil, media: Bool = false) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let account = displayName.map { Account(id: base.account.id, username: base.account.username, acct: base.account.acct, displayName: $0, avatar: base.account.avatar) } ?? base.account
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
        return Status(
            id: base.id,
            createdAt: base.createdAt,
            account: account,
            content: media ? "" : "<p>本文の1行目です。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: media ? [attachment] : []
        )
    }

    private func configuration(displayName: String? = nil, media: Bool = false, _ change: (AppSettings) -> Void) throws -> PostContentConfiguration {
        let settings = AppSettings.isolated()
        change(settings)
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
        return timeline.contentConfiguration(for: try status(displayName: displayName, media: media), base: .cell())
    }

    /// タイムラインのセルと同じく高さを測って並べ、部品の枠を返す。
    private func frames(of configuration: PostContentConfiguration) -> (view: PostContentView, frames: AppearancePreviewFrames) {
        let view = PostContentView(configuration: configuration)
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return (view, view.previewFrames())
    }

    @Test func stackedNamePutsSecondPartBelowFirstLine() throws {
        let configuration = try configuration { $0.appearance.stacksNameParts = true }
        let frames = frames(of: configuration).frames
        let first = try #require(frames[.nameFirstLineGlyphs]?.first)
        let second = try #require(frames[.nameSecondLineGlyphs]?.first)
        let primary = try #require(frames[.namePrimary]?.first)
        let secondary = try #require(frames[.nameSecondary]?.first)
        let time = try #require(frames[.time]?.first)
        let body = try #require(frames[.bodyGlyphs]?.first)

        #expect(abs(second.minY - first.maxY - configuration.metrics.nameStackSpacing) < 0.5)
        #expect(abs(secondary.minX - primary.minX) < 0.5)
        // 時刻は1段目の右端に残す。
        #expect(time.midY > first.minY && time.midY < first.maxY)
        #expect(time.maxX > secondary.maxX - 0.5)
        #expect(abs(body.minY - second.maxY - configuration.metrics.nameBodySpacing) < 0.5)
    }

    /// 2段のとき、名前と時刻の最小のすき間は、1段目の名前と時刻のあいだで示す。2段目は時刻と並ばないので、そこから測ると幅が0になる。
    @Test func stackedNameTimeGapIsMeasuredOnFirstLine() throws {
        let configuration = try configuration(displayName: String(repeating: "とても長い名前", count: 10)) { $0.appearance.stacksNameParts = true }
        let frames = frames(of: configuration).frames
        let gap = try #require(frames[.nameTimeMinGap]?.first)

        #expect(abs(gap.width - configuration.metrics.nameTimeSpacing) < 0.5, "\(gap)")
    }

    /// 本文のない投稿で2段目がアイコンより下にあっても、読み上げで指でなぞったときに投稿に止まるよう、読み上げの枠に2段目を含める。
    @Test func accessibilityFrameCoversSecondNameLine() throws {
        var configuration = try configuration(media: true) { $0.appearance.stacksNameParts = true }
        configuration.metrics.nameStackSpacing = 80
        let view = frames(of: configuration).view
        let second = try #require(view.previewFrames()[.nameSecondary]?.first)
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)

        #expect(element.accessibilityFrameInContainerSpace.contains(CGPoint(x: second.midX, y: second.midY)))
    }

    /// 名前を1つしか出さない表記では、分ける設定でも1段のまま。
    @Test func singleNamePartStaysOnOneLine() throws {
        let configuration = try configuration {
            $0.appearance.stacksNameParts = true
            $0.appearance.statusNameStyle = .nameOnly
        }
        let frames = frames(of: configuration).frames

        #expect(!configuration.isNameStacked)
        #expect(frames[.nameSecondLineGlyphs] == nil)
    }

    /// 2段に分けたあとに戻すと、2つ目は1段目の、名前の後ろに戻る。
    @Test func unstackingReturnsSecondPartToFirstLine() throws {
        let stacked = try configuration { $0.appearance.stacksNameParts = true }
        let view = frames(of: stacked).view
        view.configuration = try configuration { _ in }
        view.frame.size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.layoutIfNeeded()
        let frames = view.previewFrames()
        let primary = try #require(frames[.namePrimary]?.first)
        let secondary = try #require(frames[.nameSecondary]?.first)

        #expect(abs(secondary.midY - primary.midY) < 2)
        #expect(secondary.minX > primary.maxX)
    }

    /// アイコンの下を空けないと、本文は行の左の余白から始まる。
    @Test func wrappedBodyStartsAtRowMargin() throws {
        let configuration = try configuration { $0.appearance.wrapsBelowAvatar = true }
        let frames = frames(of: configuration).frames
        let body = try #require(frames[.bodyGlyphs]?.first)
        let avatar = try #require(frames[.avatar]?.first)

        #expect(abs(body.minX - configuration.metrics.margins.leading) < 0.5)
        #expect(body.minY >= avatar.maxY)
    }

    /// アイコンの下を空けても、アイコンと名前の位置は変わらない。本文を名前に寄せようとして、名前の行を縦に引き伸ばすと、名前が下へずれる。
    @Test(arguments: [false, true])
    func wrappingKeepsHeaderInPlace(stacked: Bool) throws {
        let plain = frames(of: try configuration { $0.appearance.stacksNameParts = stacked }).frames
        let wrapped = frames(of: try configuration {
            $0.appearance.stacksNameParts = stacked
            $0.appearance.wrapsBelowAvatar = true
        }).frames

        for part in [AppearancePreviewPart.avatar, .nameGlyphs, .namePrimary, .time] {
            let before = try #require(plain[part]?.first)
            let after = try #require(wrapped[part]?.first)
            #expect(abs(before.minY - after.minY) < 0.5, "\(part) \(before) → \(after)")
        }
    }

    /// 本文は、アイコンの下端と名前の字面の下端のうち、下にあるほうから離して置く。
    @Test(arguments: [8.0, 80.0])
    func wrappedBodyFollowsLowerOfAvatarAndName(avatarSize: Double) throws {
        var configuration = try configuration {
            $0.appearance.wrapsBelowAvatar = true
            $0.appearance.stacksNameParts = true
        }
        configuration.metrics.avatarSize = avatarSize
        let frames = frames(of: configuration).frames
        let body = try #require(frames[.bodyGlyphs]?.first)
        let avatar = try #require(frames[.avatar]?.first)
        let name = try #require(frames[.nameGlyphs]?.first)
        let header = try #require(frames[.postHeader]?.first)

        #expect(abs(header.maxY - max(avatar.maxY, name.maxY)) < 0.5)
        #expect(abs(body.minY - header.maxY - configuration.metrics.nameBodySpacing) < 0.5)
    }

    /// アイコンの下を空けないと、返信をつなぐ線を出す設定でも、線を出さない。
    @Test func wrappingHidesReplyLines() throws {
        var configuration = try configuration { $0.appearance.wrapsBelowAvatar = true }
        configuration.replyConnection = ReplyConnection(above: true, below: true)
        let frames = frames(of: configuration).frames

        #expect(configuration.showsReplyLines)
        #expect(frames[.replyLineBelow] == nil)
    }

    /// 区切り線は、行の本文の左端から引く。アイコンの下を空けるときはアイコンの列に入れず、空けないときは行の左の余白から引く。
    /// メンションは投稿の行なので投稿と同じにし、お気に入りやフォローの通知の行、人の行、すき間と読めなかった投稿の行は、いつも文字の列から引く。
    @Test(arguments: [false, true])
    func separatorStartsAtBodyLeading(wraps: Bool) throws {
        let settings = AppSettings.isolated()
        settings.appearance.wrapsBelowAvatar = wraps
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
        let status = try status()
        let margin = settings.rowMargins.leading
        let textColumn: CGFloat = settings.rowMargins.leading + settings.value(of: AppearanceCatalog.avatarSize) + settings.value(of: AppearanceCatalog.avatarSpacing)
        let mention = MastodonNotification(id: "1", type: .mention, createdAt: Date(timeIntervalSince1970: 0), account: status.account, status: status)
        let favourite = MastodonNotification(id: "2", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: status.account, status: status)
        let follow = MastodonNotification(id: "3", type: .follow, createdAt: Date(timeIntervalSince1970: 0), account: status.account, status: nil)

        #expect(timeline.separatorLeadingInset(for: .status(status)) == (wraps ? margin : textColumn))
        #expect(timeline.separatorLeadingInset(for: .notification(mention)) == (wraps ? margin : textColumn))
        #expect(timeline.separatorLeadingInset(for: .notification(favourite)) == textColumn)
        #expect(timeline.separatorLeadingInset(for: .notification(follow)) == textColumn)
        #expect(timeline.separatorLeadingInset(for: .account(status.account)) == textColumn)
        #expect(timeline.separatorLeadingInset(for: .gap(TimelineGap(newerID: "2", olderID: "1"))) == textColumn)
        #expect(timeline.separatorLeadingInset(for: .unreadable(UnreadableItem(id: "u", url: nil))) == textColumn)
    }
}
