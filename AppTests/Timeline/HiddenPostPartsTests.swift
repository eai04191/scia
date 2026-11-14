import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 「投稿の見た目」で、投稿の部品を表示しない選択肢。決まりはdocs/appearance.mdの「部品を表示しない」にある。
@Suite(.scratch, .failureState)
@MainActor
struct HiddenPostPartsTests {
    private func status(content: String = "<p>本文の1行目です。</p>", spoilerText: String = "", visibility: Status.Visibility = .public, edited: Bool = false, media: Bool = false) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
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
            account: base.account,
            content: content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media ? [attachment] : [],
            visibility: visibility,
            editedAt: edited ? base.createdAt : nil
        )
    }

    private func timeline(_ change: (AppSettings) -> Void) -> TimelineViewController {
        let settings = AppSettings.isolated()
        change(settings)
        return TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
    }

    /// タイムラインのセルと同じく高さを測って並べる。
    private func laidOut(_ configuration: PostContentConfiguration) -> PostContentView {
        let view = PostContentView(configuration: configuration)
        let size = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    private func visibleLabels(in view: UIView) -> [UILabel] {
        view.subviews.filter { !$0.isHidden }.flatMap { subview in
            (subview as? UILabel).map { [$0] } ?? visibleLabels(in: subview)
        }
    }

    private func spokenLabel(of view: PostContentView) throws -> String {
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        return try #require(element.accessibilityLabel)
    }

    // MARK: 時刻

    /// 時刻を出さなくても、公開範囲の記号と編集済みの「*」は、それぞれのスイッチに従って出す。
    @Test func hiddenTimeKeepsVisibilitySymbolAndEditedMark() throws {
        let configuration = timeline { $0.appearance.showsTime = false }
            .contentConfiguration(for: try status(visibility: .private, edited: true), base: .cell())
        let view = laidOut(configuration)

        let text = try #require(visibleLabels(in: view).compactMap(\.attributedText).first { $0.string.contains("*") })
        #expect(text.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
        // 記号、すき間を作る空白、「*」だけで、時刻の文字はない。
        #expect(text.length == 3)
        let frames = view.previewFrames()
        #expect(frames[.visibilitySymbol] != nil)
        #expect(frames[.editedMark] != nil)
    }

    /// 時刻も記号も「*」も出さなければ、時刻のラベルを出さない。
    @Test func hiddenTimeWithoutMarksHidesTimeLabel() throws {
        let configuration = timeline {
            $0.appearance.showsTime = false
            $0.appearance.showsVisibilitySymbol = false
            $0.appearance.showsEditedMark = false
        }
        .contentConfiguration(for: try status(visibility: .private, edited: true), base: .cell())
        let view = laidOut(configuration)

        #expect(view.previewFrames()[.time] == nil)
        // 消した記号と「*」の場所は、名前の行の右端で示す。
        #expect(view.previewFrames()[.visibilitySymbol] != nil)
        #expect(view.previewFrames()[.editedMark] != nil)
        #expect(try spokenLabel(of: view).contains("フォロワーのみ、編集済み、"))
    }

    // MARK: 名前の行

    /// 名前の表記を「表示しない」にすると、名前とハンドルを出さず、時刻は右端に残す。読み上げでは誰の投稿かを読む。
    @Test func noneNameStyleKeepsTimeAtTrailingEdge() throws {
        let post = try status()
        let shown = laidOut(timeline { _ in }.contentConfiguration(for: post, base: .cell())).previewFrames()
        let view = laidOut(timeline { $0.appearance.statusNameStyle = .none }.contentConfiguration(for: post, base: .cell()))
        let frames = view.previewFrames()

        #expect(frames[.namePrimary] == nil)
        #expect(frames[.nameSecondary] == nil)
        #expect(frames[.time]?.first?.maxX == shown[.time]?.first?.maxX)
        // 名前の行は残るので、本文の位置は変わらない。
        #expect(frames[.bodyGlyphs]?.first?.minY == shown[.bodyGlyphs]?.first?.minY)
        #expect(try spokenLabel(of: view).contains(post.account.displayNameOrUsername))
    }

    /// 名前の行を出さないと、本文をアイコンの上端から置く。読み上げでは名前と時刻を読む。
    @Test(arguments: [false, true])
    func hiddenNameRowPutsBodyAtAvatarTop(stacked: Bool) throws {
        let post = try status(visibility: .private, edited: true)
        let view = laidOut(timeline {
            $0.appearance.showsNameRow = false
            $0.appearance.stacksNameParts = stacked
        }.contentConfiguration(for: post, base: .cell()))
        let frames = view.previewFrames()
        let avatar = try #require(frames[.avatar]?.first)
        let body = try #require(frames[.bodyGlyphs]?.first)

        #expect(frames[.nameRow] == nil)
        #expect(frames[.namePrimary] == nil)
        #expect(frames[.nameSecondary] == nil)
        #expect(frames[.time] == nil)
        #expect(frames[.nameRowSlot] != nil)
        #expect(abs(body.minY - avatar.minY) < 0.5, "\(body) \(avatar)")
        #expect(visibleLabels(in: view).allSatisfy { $0.attributedText?.string.contains("*") != true })
        let spoken = try spokenLabel(of: view)
        #expect(spoken.contains(post.account.displayNameOrUsername))
        #expect(spoken.contains("フォロワーのみ、編集済み、"))
    }

    /// アイコンの下を空けない並べ方で名前の行を出さないと、本文をアイコンの下から置く。
    @Test func hiddenNameRowPutsBodyBelowAvatarWhenWrapping() throws {
        let configuration = timeline {
            $0.appearance.showsNameRow = false
            $0.appearance.wrapsBelowAvatar = true
        }.contentConfiguration(for: try status(), base: .cell())
        let frames = laidOut(configuration).previewFrames()
        let avatar = try #require(frames[.avatar]?.first)
        let body = try #require(frames[.bodyGlyphs]?.first)

        #expect(abs(body.minY - avatar.maxY - configuration.metrics.nameBodySpacing) < 0.5, "\(body) \(avatar)")
        #expect(abs(body.minX - configuration.metrics.margins.leading) < 0.5)
    }

    // MARK: アイコン

    /// アイコンを出さないと、アイコンの列と文字の列とのあいだを取らず、名前と本文を行の左の余白から置く。
    @Test func hiddenAvatarRemovesItsColumn() throws {
        let configuration = timeline { $0.appearance.showsAvatar = false }.contentConfiguration(for: try status(), base: .cell())
        let view = laidOut(configuration)
        let frames = view.previewFrames()
        let leading = configuration.metrics.margins.leading

        #expect(configuration.avatar == nil)
        #expect(frames[.avatar]?.first?.width == 0)
        #expect(abs(try #require(frames[.namePrimary]?.first).minX - leading) < 0.5)
        #expect(abs(try #require(frames[.bodyGlyphs]?.first).minX - leading) < 0.5)
    }

    /// アイコンも名前の行も出さない投稿は、本文だけを上下の余白のあいだに置く。
    @Test func bodyAloneFillsRowBetweenMargins() throws {
        let post = try status(content: "<p>1行目</p><p>2行目</p><p>3行目</p><p>4行目</p>")
        let shown = laidOut(timeline { _ in }.contentConfiguration(for: post, base: .cell()))
        let configuration = timeline {
            $0.appearance.showsAvatar = false
            $0.appearance.showsNameRow = false
        }.contentConfiguration(for: post, base: .cell())
        let view = laidOut(configuration)
        let body = try #require(view.previewFrames()[.bodyGlyphs]?.first)
        let shownBody = try #require(shown.previewFrames()[.bodyGlyphs]?.first)

        #expect(abs(body.minY - configuration.metrics.margins.top) < 0.5, "\(body)")
        // 本文の下の空きは、名前の行とアイコンを出しているときと同じ。
        #expect(abs((view.bounds.maxY - body.maxY) - (shown.bounds.maxY - shownBody.maxY)) < 0.5, "\(body) \(view.bounds)")
    }

    /// アイコンを出さないと、名前の上の行の記号を文字の列の先頭に置き、その後ろに名前を続ける。記号を行の外へ出さない。
    @Test func hiddenAvatarPutsContextSymbolInTextColumn() throws {
        let original = try status()
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: "200", createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        let configuration = timeline {
            $0.appearance.showsAvatar = false
            $0.appearance.showsBoosterAvatar = false
        }.contentConfiguration(for: boost, base: .cell())
        let frames = laidOut(configuration).previewFrames()
        let symbol = try #require(frames[.contextSymbol]?.first)
        let text = try #require(frames[.contextText]?.first)

        #expect(abs(symbol.minX - configuration.metrics.margins.leading) < 0.5, "\(symbol)")
        #expect(abs(text.minX - symbol.maxX - configuration.metrics.contextSymbolSpacing) < 0.5, "\(symbol) \(text)")
    }

    // MARK: 中身

    /// 本文を出さないと、本文のあった場所だけを示し、行は本文の分だけ低くなる。
    @Test func hiddenBodyIsNotDrawn() throws {
        let post = try status()
        let shown = laidOut(timeline { _ in }.contentConfiguration(for: post, base: .cell()))
        let view = laidOut(timeline { $0.appearance.showsBody = false }.contentConfiguration(for: post, base: .cell()))
        let frames = view.previewFrames()

        #expect(frames[.bodyText] == nil)
        #expect(frames[.bodySlot] != nil)
        #expect(view.bounds.height <= shown.bounds.height)
        #expect(try !spokenLabel(of: view).contains("本文の1行目"))
    }

    /// 本文を出さなくても、添付ファイルは出す。
    @Test func hiddenBodyKeepsMedia() throws {
        let frames = laidOut(timeline { $0.appearance.showsBody = false }.contentConfiguration(for: try status(media: true), base: .cell())).previewFrames()

        #expect(frames[.bodyText] == nil)
        #expect(frames[.media] != nil)
    }

    /// 注意書きを出さないと、注意書きのある投稿の本文を、注意書きのない投稿と同じく出す。
    @Test func hiddenSpoilerShowsBody() throws {
        let frames = laidOut(timeline { $0.appearance.showsSpoiler = false }.contentConfiguration(for: try status(spoilerText: "ネタバレ"), base: .cell())).previewFrames()

        #expect(frames[.spoiler] == nil)
        #expect(frames[.spoilerSlot] != nil)
        #expect(frames[.bodyText] != nil)
    }

    /// メディアを出さないと、添付ファイルのサムネイルを並べない。
    @Test func hiddenMediaIsNotDrawn() throws {
        let frames = laidOut(timeline { $0.appearance.showsMedia = false }.contentConfiguration(for: try status(media: true), base: .cell())).previewFrames()

        #expect(frames[.media] == nil)
        #expect(frames[.mediaSlot] != nil)
        #expect(frames[.bodyText] != nil)
    }

    /// 「続きを読む」を出さなくても、長い本文は切る。その場で広げる操作は、読み上げにも出さない。
    @Test func hiddenReadMoreKeepsBodyTruncated() throws {
        let long = try status(content: (1...40).map { "<p>\($0)行目</p>" }.joined())
        let shown = laidOut(timeline { _ in }.contentConfiguration(for: long, base: .cell()))
        let view = laidOut(timeline { $0.appearance.showsReadMore = false }.contentConfiguration(for: long, base: .cell()))

        #expect(shown.previewFrames()[.readMore] != nil)
        #expect(view.previewFrames()[.readMore] == nil)
        #expect(abs(view.bounds.height - shown.bounds.height) < 0.5)
        let element = try #require(view.accessibilityElements?.first as? UIAccessibilityElement)
        #expect(element.accessibilityCustomActions?.contains { $0.name == ReadMoreButton.title } != true)
    }

    /// 光を出さないと、お気に入りやブーストをした投稿でも光の高さを0にする。
    @Test func hiddenReactionGlowHasNoHeight() throws {
        let settings = AppSettings.isolated()
        settings.appearance.showsReactionGlow = false

        #expect(ReactionGlow.Style(tuning: TuningStore(defaults: nil), settings: settings).height == 0)
    }

    /// 引用とXの投稿の囲みのアイコンを出さないと、大きさも名前とのすき間も取らない。
    @Test func hiddenEmbedAvatarHasNoSize() throws {
        let settings = AppSettings.isolated()
        settings.appearance.showsEmbedAvatar = false
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
        let content = timeline.postContentBuilder.quote(try status(), spoiler: nil, media: nil, base: .cell())

        #expect(content.avatarSize == 0)
        #expect(content.avatarNameSpacing == 0)
        #expect(content.header?.avatar.url == nil)
    }

    // MARK: 指摘への対応

    /// 時刻を出していなくても、読み上げの時刻は時間がたつと書き直す。
    @Test func hiddenTimeStillRefreshesSpokenTime() throws {
        let post = try status()
        let view = PostContentView(configuration: timeline { $0.appearance.showsTime = false }.contentConfiguration(for: post, base: .cell()))
        view.now = { post.createdAt.addingTimeInterval(10) }
        view.refreshTime(now: post.createdAt.addingTimeInterval(10))
        let before = try spokenLabel(of: view)
        view.now = { post.createdAt.addingTimeInterval(7_200) }
        view.refreshTime(now: post.createdAt.addingTimeInterval(7_200))

        #expect(try spokenLabel(of: view) != before)
    }

    /// 名前の行を出さないときは、名前を組み立てない。名前のカスタム絵文字の画像を読まないため。
    @Test func hiddenNameRowDoesNotRenderNames() throws {
        let configuration = timeline { $0.appearance.showsNameRow = false }.contentConfiguration(for: try status(), base: .cell())

        #expect(configuration.nameParts.isEmpty)
    }

    /// 出さない設定の本文と引用は、自動翻訳に頼まない。
    @Test func hiddenBodyIsNotTranslated() throws {
        let post = try status()

        #expect(timeline { _ in }.translationSources(of: post).count == 1)
        #expect(timeline { $0.appearance.showsBody = false }.translationSources(of: post).isEmpty)
    }

    /// カスタム絵文字のスイッチは、「本文」のものは本文に、「名前の行」のものは名前にだけ効く。描かない絵文字は、ショートコードの文字も出さない。
    @Test func hiddenCustomEmojisAreNotDrawn() throws {
        let base = try status()
        let url = try #require(URL(string: "https://files.example.social/blob.png"))
        let emoji = CustomEmoji(shortcode: "blob", url: url, staticUrl: url)
        let account = Account(id: base.account.id, username: base.account.username, acct: base.account.acct, displayName: "名前:blob:", avatar: base.account.avatar, emojis: [emoji])
        let post = Status(id: base.id, createdAt: base.createdAt, account: account, content: "<p>前:blob:後</p>", spoilerText: "", url: nil, emojis: [emoji])
        let shown = timeline { _ in }.contentConfiguration(for: post, base: .cell())
        let hidden = timeline { $0.appearance.showsCustomEmojis = false }.contentConfiguration(for: post, base: .cell())

        #expect(shown.body.length == 3)
        #expect(hidden.body.string == "前後")
        #expect(hidden.nameParts.first?.length == shown.nameParts.first?.length)
        let hiddenName = timeline { $0.appearance.showsNameCustomEmojis = false }.contentConfiguration(for: post, base: .cell())
        #expect(hiddenName.nameParts.first?.string == "名前")
        #expect(hiddenName.body.length == shown.body.length)
        // 絵文字だけの本文は、あいだの空白や改行を残さず空にする。
        let emojiOnly = Status(id: base.id, createdAt: base.createdAt, account: account, content: "<p>:blob: :blob:</p><p>:blob:</p>", spoilerText: "", url: nil, emojis: [emoji])
        #expect(timeline { $0.appearance.showsCustomEmojis = false }.contentConfiguration(for: emojiOnly, base: .cell()).body.length == 0)
    }

    /// 投稿のアイコンを出さないと、投稿の区切り線は本文の左端（行の左の余白）から引く。アイコンを出したままの通知や人の行は、アイコンの列の右から引く。
    @Test func hiddenAvatarMovesOnlyPostSeparators() {
        let settings = AppSettings.isolated()
        settings.appearance.showsAvatar = false
        let column = settings.rowMargins.leading + settings.value(of: AppearanceCatalog.avatarSize) + settings.value(of: AppearanceCatalog.avatarSpacing)

        #expect(abs(settings.postSeparatorLeading - settings.rowMargins.leading) < 0.001)
        #expect(abs(settings.textColumnLeading - column) < 0.001)
    }

    // MARK: スレッド

    /// スレッドで開いた投稿は、表示しない設定にした部品も出す。ほかの投稿は設定に従う。スイッチをオフにすると、開いた投稿も設定に従う。
    @Test(arguments: [true, false])
    func threadFocusRevealsHiddenParts(reveals: Bool) throws {
        let focus = try status()
        let other = Status(id: "999", createdAt: focus.createdAt, account: focus.account, content: "<p>返信です。</p>", spoilerText: "", url: nil)
        let controller = timeline {
            $0.appearance.showsBody = false
            $0.appearance.showsAvatar = false
            $0.appearance.statusNameStyle = .none
            $0.appearance.revealsAllPartsInThread = reveals
        }
        controller.threadFocusID = focus.id
        let focused = controller.contentConfiguration(for: focus, base: .cell())
        let replied = controller.contentConfiguration(for: other, base: .cell())

        #expect((focused.body.length > 0) == reveals)
        #expect((focused.avatar != nil) == reveals)
        #expect(focused.nameParts.isEmpty != reveals)
        #expect(replied.body.length == 0)
        #expect(replied.avatar == nil)
        // 隣の投稿にアイコンがないので、開いた投稿でも返信をつなぐ線を引かない。
        #expect(!focused.showsReplyLines)
    }

    /// スレッドで開いた投稿は、アクションバーの件数を出さない設定でも件数を出す。ほかの投稿は設定どおり出さない。
    @Test func threadFocusRevealsActionBarCounts() throws {
        let base = try status()
        let focus = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, favouritesCount: 3)
        let other = Status(id: "999", createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, favouritesCount: 3)
        let controller = timeline {
            $0.appearance.showsActionBar = true
            $0.appearance.showsActionBarCounts = false
        }
        controller.threadFocusID = focus.id

        #expect(controller.contentConfiguration(for: focus, base: .cell()).actionBar?.buttons.contains { $0.count == 3 } == true)
        #expect(controller.contentConfiguration(for: other, base: .cell()).actionBar?.buttons.contains { $0.count != nil } == false)
    }
}
