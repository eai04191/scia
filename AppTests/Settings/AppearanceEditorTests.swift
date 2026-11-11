import ImageIO
import SciaCore
import SwiftUI
import Testing
import SciaTesting
import UIKit
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct AppearanceEditorTests {
    private func makeSettings() throws -> AppSettings {
        let defaults = TestScratch.defaults("AppearanceEditorTests")
        return AppSettings(defaults: defaults)
    }

    private let large = UITraitCollection(preferredContentSizeCategory: .large)

    /// 既定の差では、設定を足す前と同じ大きさで描く。本文と時刻はsubheadline、名前はbody、リンクカードのサイト名はcaption1、投票の票数と注意書きのボタンはfootnote。
    @Test func defaultTypographyMatchesPreviousTextStyles() throws {
        let typography = PostTypography(settings: try makeSettings())
        func size(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: large).pointSize
        }
        #expect(typography.font(.body, compatibleWith: large).pointSize == size(.subheadline))
        #expect(typography.font(.time, compatibleWith: large).pointSize == size(.subheadline))
        #expect(typography.font(.namePrimary, compatibleWith: large).pointSize == size(.body))
        #expect(typography.font(.linkCardDetail, compatibleWith: large).pointSize == size(.caption1))
        #expect(typography.font(.pollFooter, compatibleWith: large).pointSize == size(.footnote))
        #expect(typography.font(.spoilerButton, compatibleWith: large).pointSize == size(.footnote))
        #expect(typography.font(.namePrimary, compatibleWith: large).fontDescriptor.symbolicTraits.contains(.traitBold))
        // 通知の誰が何をしたかの行は、本文（subheadline）と太字の名前（body）のあいだの大きさにする。ハンドルとメンションの上の行は本文と同じ。
        #expect(typography.font(.notificationHeader, compatibleWith: large).pointSize == size(.subheadline) + 1)
        #expect(typography.font(.notificationAccount, compatibleWith: large).pointSize == size(.subheadline))
        #expect(typography.font(.notificationContext, compatibleWith: large).pointSize == size(.subheadline))
    }

    /// 本文を大きくすると、ほかの文字も本文との差を保って一緒に大きくなる。
    @Test func bodyOffsetMovesEveryRole() throws {
        let settings = try makeSettings()
        let before = PostTypography(settings: settings)
        settings.setValue(3, for: AppearanceCatalog.bodyText)
        let after = PostTypography(settings: settings)
        for role in PostTypography.Role.allCases {
            #expect(after.standardPointSize(role) == before.standardPointSize(role) + 3)
        }
    }

    /// iPhoneの文字サイズを大きくすると、設定の差を付けた文字も大きくなる。
    @Test func typographyFollowsContentSizeCategory() throws {
        let settings = try makeSettings()
        settings.setValue(2, for: AppearanceCatalog.namePrimaryText)
        let typography = PostTypography(settings: settings)
        let larger = UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)
        #expect(typography.font(.namePrimary, compatibleWith: larger).pointSize > typography.font(.namePrimary, compatibleWith: large).pointSize)
    }

    /// 投稿の組み立ては、設定の文字の大きさで本文を描く。
    @Test func builderUsesBodyText() throws {
        let settings = try makeSettings()
        settings.setValue(4, for: AppearanceCatalog.bodyText)
        let timeline = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let configuration = timeline.contentConfiguration(for: status, base: .cell())
        let font = try #require(configuration.body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize == PostTypography(settings: settings).font(.body).pointSize)
    }

    @Test func verticalGapIsBandBetweenParts() {
        let frames: AppearancePreviewFrames = [
            .nameRow: [CGRect(x: 60, y: 10, width: 300, height: 20)],
            .bodyText: [CGRect(x: 60, y: 35, width: 280, height: 40)],
        ]
        let found = AppearanceHighlight.verticalGap(above: [.nameRow], below: [.spoiler, .bodyText]).locate(in: [frames])
        #expect(found?.row == 0)
        #expect(found?.rects == [CGRect(x: 60, y: 30, width: 300, height: 5)])
    }

    /// 余白が0でも見えるよう、細い帯にする。
    @Test func zeroGapStillShowsThinBand() {
        let frames: AppearancePreviewFrames = [
            .avatar: [CGRect(x: 16, y: 10, width: 40, height: 40)],
            .nameRow: [CGRect(x: 56, y: 10, width: 300, height: 20)],
        ]
        let found = AppearanceHighlight.horizontalGap(leading: [.avatar], trailing: [.nameRow]).locate(in: [frames])
        #expect(found?.rects.first?.width == AppearanceHighlight.minimumGapThickness)
        #expect(found?.rects.first?.midX == 56)
    }

    /// 本文のない投稿だけの余白は、本文のある行では示さず、本文のない行を探す。
    @Test func gapSkipsRowsWithAbsentPart() throws {
        let withBody: AppearancePreviewFrames = [
            .nameGlyphs: [CGRect(x: 60, y: 10, width: 300, height: 20)],
            .bodyText: [CGRect(x: 60, y: 35, width: 280, height: 40)],
            .media: [CGRect(x: 60, y: 85, width: 280, height: 100)],
        ]
        let mediaOnly: AppearancePreviewFrames = [
            .nameGlyphs: [CGRect(x: 60, y: 10, width: 300, height: 20)],
            .media: [CGRect(x: 60, y: 42, width: 280, height: 100)],
        ]
        let highlight = try #require(AppearanceHighlight(AppearanceCatalog.nameMediaSpacing))
        let found = highlight.locate(in: [withBody, mediaOnly])
        #expect(found?.row == 1)
        #expect(found?.rects == [CGRect(x: 60, y: 30, width: 300, height: 12)])
    }

    /// プレビューの見本だけで、どの項目も場所を示せる。引用の区画は、いつも見本へ足す引用の囲みで示す。
    @Test func samplesShowEveryItem() throws {
        let settings = try makeSettings()
        // アクションバーは、いつも出す設定のときだけすべての見本に出る。
        settings.appearance.showsActionBar = true
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 2_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, revision: 0))
        preview.layoutIfNeeded()
        let rows = preview.rowFrames()
        for item in AppearanceCatalog.values {
            let highlight = try #require(AppearanceHighlight(item), "\(item.id)に示す場所がありません")
            #expect(highlight.locate(in: rows) != nil, "\(item.id)の場所が見本にありません")
        }
        for choice in AppearanceChoice.allCases {
            #expect(choice.highlight.locate(in: rows) != nil, "\(choice)の場所が見本にありません")
        }
    }

    /// 分類の画面の見本で、その分類のどの項目も、触っている間は場所を示せる。
    @Test(arguments: AppearanceCatalog.groups.map(\.id))
    func groupSamplesShowTheirItems(group: AppearanceGroup.ID) throws {
        let settings = try makeSettings()
        let values = try #require(AppearanceCatalog.groups.first { $0.id == group }).values
        for item in values {
            let highlight = try #require(AppearanceHighlight(item), "\(item.id)に示す場所がありません")
            let rows = layOutSamples(settings, groups: [group], focus: .value(item))
            #expect(highlight.locate(in: rows) != nil, "\(item.id)の場所が\(group)の見本にありません")
        }
        for choice in Self.choices[group] ?? [] {
            let rows = layOutSamples(settings, groups: [group], focus: .choice(choice))
            #expect(choice.highlight.locate(in: rows) != nil, "\(choice)の場所が\(group)の見本にありません")
        }
    }

    /// 投稿の添付ファイルは本文の下、囲みの添付ファイルだけ本文の右に並べるときも、右に並べる写真にだけ効く項目を触っている間は、その場所を示せる。
    @Test func besideItemsShowWhenOnlyEmbedIsBeside() throws {
        let settings = try makeSettings()
        settings.appearance.mediaArrangement = .belowBody
        settings.appearance.embedMediaArrangement = .besideBody
        // 項目の場所は、右に並べた写真がなければ下に並べた写真で示すので、右に並べた写真が見本にあるかを直接確かめる。
        func showsBesideMedia(_ focus: AppearanceFocus) -> Bool {
            layOutSamples(settings, groups: ["media"], focus: focus).contains { $0[.besideMedia] != nil || $0[.xPostBesideMedia] != nil }
        }
        #expect(showsBesideMedia(.value(AppearanceCatalog.mediaBesideSide)))
        #expect(showsBesideMedia(.choice(.tiltsStackedPhotos)))
    }

    /// 分類の画面の見本に、要らない見本がない。どの見本も、除くとその分類のどれかの項目の場所を示せなくなる。
    /// 既定の設定のほか、その分類の選ぶ項目を1つずつ変えた設定でも確かめる。設定によって、その見本にしか出ない部品があるため（片方だけの光を全幅にすると、真ん中の境目は両方をした投稿にしか出ない、など）。
    /// 場所は、項目が効く本来の部品で確かめる（`primary`）。投稿のあいだに出る項目は、隣り合う投稿があるときだけ示せたことにする（`betweenPosts`）。
    /// 確かめるのは、どの見本もどれかの項目に要ることだけで、見本の中身が小さいかは確かめられない。触っている間だけ足す見本は、その項目のための見本なので見ない。
    @Test(arguments: AppearanceCatalog.groups.map(\.id))
    func groupSamplesAreAllNeeded(group: AppearanceGroup.ID) throws {
        let values = try #require(AppearanceCatalog.groups.first { $0.id == group }).values
        let choices = Self.choices[group] ?? []
        let focuses = values.map { AppearanceFocus.value($0) } + choices.map { AppearanceFocus.choice($0) }
        var variants = [AppSettings(defaults: TestScratch.defaults("AppearanceEditorTests-needed"))]
        for choice in choices {
            let settings = AppSettings(defaults: TestScratch.defaults("AppearanceEditorTests-needed-\(choice)"))
            _ = AppearanceSheets.change(choice, in: settings)
            variants.append(settings)
        }
        let sampleIDs = AppearanceSamples.sampleIDs(for: [group], focus: nil, appearance: try #require(variants.first).appearance)
        for sampleID in sampleIDs.sorted() {
            let needed = variants.contains { settings in
                focuses.contains { focus in
                    Self.locates(focus, in: layOutSamples(settings, groups: [group], focus: focus))
                        && !Self.locates(focus, in: layOutSamples(settings, groups: [group], focus: focus, excluding: sampleID))
                }
            }
            #expect(needed, "\(group)の見本\(sampleID)は、除いてもその分類のすべての項目の場所を示せます")
        }
    }

    /// 項目の場所を、本来の部品で示せるか。
    private static func locates(_ focus: AppearanceFocus, in rows: [AppearancePreviewFrames]) -> Bool {
        if betweenPosts.contains(focus), rows.count < 2 { return false }
        let highlight: AppearanceHighlight? = switch focus {
        case .value(let item): AppearanceHighlight(item)
        case .choice(let choice): choice.highlight
        }
        return highlight.map { primary($0).locate(in: rows) != nil } ?? false
    }

    /// 項目が効く本来の部品。プレビューでは、本来の部品が見本にないとき（件数を表示しない設定で件数がない、など）に代わりの場所を示すが、その場所には項目が効かないので数えない。
    private static func primary(_ highlight: AppearanceHighlight) -> AppearanceHighlight {
        switch highlight {
        case .firstOf(let candidates): candidates.first.map(primary) ?? highlight
        case .firstPart(let parts): parts.first.map { .part($0) } ?? highlight
        default: highlight
        }
    }

    /// 投稿の中ではなく、上下の投稿とのあいだの見た目を決める項目。投稿が1件だけでは、隣の投稿とどう並ぶかが分からない。
    private static let betweenPosts: Set<AppearanceFocus> = [
        .value(AppearanceCatalog.rowPaddingTop),
        .value(AppearanceCatalog.rowPaddingBottom),
        .choice(.showsSeparators),
    ]

    /// 分類ごとの、選んで決める項目。`AppearanceEditorView.choices(of:)`に並べたものと同じにする。
    private static let choices: [AppearanceGroup.ID: [AppearanceChoice]] = [
        "row": [.showsSeparators],
        "context": [.contextNameStyle, .showsContextSymbol, .showsBoosterAvatar, .showsReplyLabel],
        "avatar": [.avatarShape, .showsAvatarBorder, .animatesAvatars, .wrapsBelowAvatar, .showsReplyLines],
        "name": [.nameStyle, .stacksNameParts, .timeStyle, .boldsName, .showsTime, .showsVisibilitySymbol, .showsEditedMark],
        "body": [.glyphLanguage, .emojiStyle, .animatesCustomEmojis],
        "media": [.mediaArrangement, .embedMediaArrangement, .tiltsStackedPhotos, .showsMediaBadges],
        "linkCard": [.showsLinkCard, .boldsLinkCardTitle, .showsLinkCardImage, .linkCardThumbnailSide, .showsLinkCardSite],
        AppearanceCatalog.actionBarGroupID: [.showsActionBar, .showsActionBarCounts],
        "reactionGlow": [.drawsReactionGlowInHDR, .reactionGlowIcons, .reactionGlowFillsWidthWhenAlone, .reactionGlowLightFavouriteColor],
    ]

    /// 分類ごとの選んで決める項目のリストに、漏れがない。
    @Test func groupChoicesCoverEveryChoice() {
        #expect(Set(Self.choices.values.joined()) == Set(AppearanceChoice.allCases))
    }

    /// どの分類も開いていなければ、見本は1件だけにする。
    @Test func closedGroupsShowOneSample() throws {
        let samples = AppearanceSamples(settings: try makeSettings(), tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(samples.configurations(colorScheme: .light, revision: 0, groups: []).count == 1)
    }

    /// 見本の高さは、高さを合わせ直すきっかけが変わったときに渡し直し、値を変えて高さが変わっても渡さない。
    @Test func fitsHeightOnlyWhenFitRevisionChanges() async throws {
        let settings = try makeSettings()
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        let preview = AppearanceTimelinePreviewController(timeline: samples.timeline)
        preview.view.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        var heights: [CGFloat] = []
        preview.onFitHeight = { heights.append($0) }
        func apply(fitRevision: Int) {
            preview.apply(entries: samples.entries(colorScheme: .light, groups: ["body"]), fitRevision: fitRevision)
            preview.view.layoutIfNeeded()
        }
        apply(fitRevision: 0)
        settings.setValue(40, for: AppearanceCatalog.bodyText)
        apply(fitRevision: 0)
        settings.setValue(20, for: AppearanceCatalog.bodyText)
        apply(fitRevision: 1)
        // 渡すのは並べ終えたあとなので、2回目が届くまで待つ。値を変えたときに渡していれば、3回渡る。
        try await waitUntil { heights.count >= 2 }
        #expect(heights.count == 2)
        #expect(heights[1] == samples.timeline.collectionView.collectionViewLayout.collectionViewContentSize.height)
    }

    /// 同梱した見本の写真は、どれも読めて、比率の上限を見せる写真は既定の上限を超えている。上限ちょうどでは、値を変えても見本が変わらないため。
    @Test func previewPhotosDecode() throws {
        func size(_ photo: PreviewPhoto) throws -> CGSize {
            let url = try #require(PreviewImages.photoURL(photo), "\(photo)が同梱されていません")
            let image = try #require(PreviewImages.data(for: url).flatMap(UIImage.init(data:)), "\(photo)を読めません")
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        let tall = try size(.tall)
        #expect(tall.width / tall.height < AppearanceCatalog.mediaTallestAspectRatio.defaultValue)
        let wide = try size(.wide)
        #expect(wide.width / wide.height > AppearanceCatalog.mediaWidestAspectRatio.defaultValue)
        _ = try size(.gridFirst)
        _ = try size(.gridSecond)
    }

    /// 2×2に並べたサムネイルでは、横の2つと縦の2つのすき間を示し、斜めの組は示さない。
    @Test func gapsBetweenTiles() {
        let tiles = [
            CGRect(x: 0, y: 0, width: 100, height: 50),
            CGRect(x: 104, y: 0, width: 100, height: 50),
            CGRect(x: 0, y: 54, width: 100, height: 50),
            CGRect(x: 104, y: 54, width: 100, height: 50),
        ]
        let gaps = AppearanceHighlight.gaps(between: tiles)
        #expect(Set(gaps.map { "\($0)" }) == Set([
            CGRect(x: 100, y: 0, width: 4, height: 50),
            CGRect(x: 0, y: 50, width: 100, height: 4),
            CGRect(x: 104, y: 50, width: 100, height: 4),
            CGRect(x: 100, y: 54, width: 4, height: 50),
        ].map { "\($0)" }))
    }

    /// ALTやGIFのバッジは、メディア全体ではなくサムネイルの中のバッジの場所を示し、消しても同じ場所を示す。
    @Test(arguments: [true, false])
    func mediaBadgeSlotStaysWhenHidden(showsBadges: Bool) throws {
        let settings = try makeSettings()
        settings.appearance.showsMediaBadges = showsBadges
        let row = try #require(layOutSamples(settings).first { $0[.mediaBadgeSlot] != nil })
        let badges = try #require(row[.mediaBadgeSlot])
        let media = try #require(row[.media]?.first)
        for badge in badges {
            #expect(badge.width > 0 && badge.height > 0)
            #expect(media.contains(badge))
            #expect(badge.width < media.width && badge.height < media.height)
        }
    }

    /// 見本のアイコンと絵文字には、静止画と別に、何コマもあるアニメーション版がある。アニメーションを再生する設定の違いを、プレビューで見せるため。
    /// アニメーション版も、ほかの見本の画像と同じく、通信の層を通さずに読む。
    @Test func samplesHaveAnimatedAvatar() async throws {
        let still = try #require(PreviewImages.avatarURL())
        let animated = try #require(PreviewImages.animatedAvatarURL())
        #expect(animated != still)
        let data = try await AppDependencies.imageData(from: animated)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) > 1)
    }

    /// 光の高さと濃さは、設定ではHDRのときの値を選び、ライトでHDRを使わずに描くときは、決まった割合で低く薄くする。
    /// 既定では、設定に移す前にチューニングで決めていた値（高さ64ptと38pt、ライトの濃さ0.95と0.3）になる。
    @Test func reactionGlowStyleScalesLightSDR() throws {
        let settings = try makeSettings()
        let tuning = TuningStore(defaults: nil)
        let standard = ReactionGlow.Style(tuning: tuning, settings: settings)
        #expect(standard.height == 64)
        #expect(abs(standard.lightSDRHeight - 38) < 0.001)
        #expect(standard.lightHDROpacity == 0.95)
        #expect(abs(standard.lightOpacity - 0.3) < 0.001)
        settings.setValue(100, for: AppearanceCatalog.reactionGlowHeight)
        settings.setValue(0.5, for: AppearanceCatalog.reactionGlowLightOpacity)
        settings.appearance.reactionGlowIcons = .scattered
        settings.appearance.reactionGlowLightFavouriteColor = .yellow
        let changed = ReactionGlow.Style(tuning: tuning, settings: settings)
        #expect(changed.height == 100)
        #expect(abs(changed.lightSDRHeight - 100 * 38 / 64) < 0.001)
        #expect(changed.lightHDROpacity == 0.5)
        #expect(abs(changed.lightOpacity - 0.5 * 0.3 / 0.95) < 0.001)
        #expect(changed.iconStyle == .scattered)
        #expect(changed.lightFavouriteIsYellow)
    }

    /// アイコンを出すと、光の項目はアイコンの場所を示す。出さないときは、アイコンが出る光を示す。
    @Test(arguments: [ReactionGlowIcons.none, .atBottom, .scattered])
    func reactionGlowIconItemsShowIcons(icons: ReactionGlowIcons) throws {
        let settings = try makeSettings()
        settings.appearance.reactionGlowIcons = icons
        let rows = layOutSamples(settings)
        let highlight = try #require(AppearanceHighlight(AppearanceCatalog.reactionGlowIconSize))
        let found = try #require(highlight.locate(in: rows))
        let row = rows[found.row]
        let expected = icons == .none ? row[.reactionGlow] : row[.reactionGlowIcons]
        #expect(found.rects == expected)
        #expect((row[.reactionGlowIcons] != nil) == (icons != .none))
    }

    /// 「片方だけのときは全幅を光らせる」は、片方だけをした見本の投稿の光を示す。両方をした投稿では、切り替えても見た目が変わらないため。
    @Test func fillsWidthChoiceShowsGlowOfSingleReaction() throws {
        let rows = layOutSamples(try makeSettings())
        let found = try #require(AppearanceChoice.reactionGlowFillsWidthWhenAlone.highlight.locate(in: rows))
        #expect(rows[found.row][.reactionGlowAlone] != nil)
    }

    /// 光の高さを0にしても、光があった下の端を示す。高さを変えている最中に、示す場所が消えないようにするため。
    @Test func zeroGlowHeightStillShowsPlace() throws {
        let settings = try makeSettings()
        settings.setValue(0, for: AppearanceCatalog.reactionGlowHeight)
        let highlight = try #require(AppearanceHighlight(AppearanceCatalog.reactionGlowHeight))
        #expect(highlight.locate(in: layOutSamples(settings)) != nil)
    }

    /// アイコンを大きくして散らしても、アイコンは消えない。濃さは、下の余白に収めて縮めたあとの大きさで、光源からの遠さを測って決めるため。
    @Test func largeScatteredIconsStayVisible() throws {
        let settings = try makeSettings()
        settings.appearance.reactionGlowIcons = .scattered
        settings.setValue(200, for: AppearanceCatalog.reactionGlowIconSize)
        let row = try #require(layOutSamples(settings).first { $0[.reactionGlow] != nil })
        #expect(row[.reactionGlowIcons] != nil)
    }

    /// 光っている投稿にも、タイムラインと同じく区切り線を引くので、区切り線の場所も示す。
    @Test func litRowHasSeparator() throws {
        let rows = layOutSamples(try makeSettings())
        let lit = try #require(rows.first { $0[.reactionGlow] != nil })
        #expect(lit[.separatorLine] != nil)
        #expect(AppearanceChoice.showsSeparators.highlight.locate(in: rows) != nil)
    }

    /// 外観ごとにしか効かない項目を触っている間は、プレビューをその外観で描く。ほかの項目では、端末の外観のまま描く。
    @Test func appearanceSpecificItemsSwitchPreviewScheme() {
        #expect(AppearanceFocus.value(AppearanceCatalog.reactionGlowDarkOpacity).colorScheme == .dark)
        #expect(AppearanceFocus.value(AppearanceCatalog.reactionGlowLightOpacity).colorScheme == .light)
        #expect(AppearanceFocus.choice(.reactionGlowLightFavouriteColor).colorScheme == .light)
        #expect(AppearanceFocus.value(AppearanceCatalog.reactionGlowHeight).colorScheme == nil)
        #expect(AppearanceFocus.choice(.drawsReactionGlowInHDR).colorScheme == nil)
    }

    /// 既定値と範囲の両端で、見本の投稿を並べて落ちず、行の高さが有限になる。投稿は起動してすぐ描くため、ある値で落ちると、起動するたびに落ちて設定まで戻れない。
    /// 高さはタイムラインのセルと同じく、大きな高さを目安に、高さを譲れる優先度で測る。高さの決まらない制約があると、目安の高さまで伸びる。
    /// - Parameter extreme: 全項目を最小にするならfalse、最大にするならtrue、既定値のままならnil。
    @Test(arguments: [nil, false, true] as [Bool?])
    func extremesLayOutWithFiniteHeights(extreme: Bool?) throws {
        let settings = try makeSettings()
        if let atMaximum = extreme {
            for item in AppearanceCatalog.values {
                settings.setValue(atMaximum ? item.range.upperBound : item.range.lowerBound, for: item)
            }
        }
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        let configurations = samples.configurations(colorScheme: .light, revision: 0)
        for (index, configuration) in configurations.enumerated() {
            let view = PostContentView(configuration: configuration)
            let height = view.systemLayoutSizeFitting(
                CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            #expect(height.isFinite && height > 0 && height < 100_000, "見本の\(index)番目の高さが\(height)になりました")
        }
        // どの項目の場所を探しても、落ちない。
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        preview.apply(configurations)
        preview.layoutIfNeeded()
        let rows = preview.rowFrames()
        for item in AppearanceCatalog.values {
            _ = AppearanceHighlight(item)?.locate(in: rows)
        }
    }

    /// すき間を示す帯の太さは、その項目の値と同じになる。帯がラベルの枠から測られていると、文字の上下の余白の分だけずれる。
    /// 名前と時刻の最小のすき間は、名前が時刻に詰まった投稿で測る。
    @Test(arguments: AppearanceCatalog.values.filter { item in
        item.unit == .point && AppearanceHighlight(item)?.measuresGap == true
    })
    func gapBandMatchesValue(item: AppearanceValue) throws {
        let settings = try makeSettings()
        // 名前の後ろに添える部分がないと、そのすき間を示せないため、名前の上の行にもハンドルを出す。
        settings.appearance.contextNameStyle = .nameAndAcct
        // 1段目と2段目のあいだは、2段に分けないと示せない。
        settings.appearance.stacksNameParts = item == AppearanceCatalog.nameStackSpacing
        // アクションバーは、いつも出す設定のときだけすべての見本に出る。
        settings.appearance.showsActionBar = item == AppearanceCatalog.actionBarSpacing
        let value = item.defaultValue + 3
        settings.setValue(value, for: item)
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 4_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, revision: 0))
        preview.layoutIfNeeded()
        let found = try #require(AppearanceHighlight(item)?.locate(in: preview.rowFrames()), "\(item.id)の場所が見本にありません")
        for rect in found.rects {
            let thickness = min(rect.width, rect.height)
            #expect(abs(thickness - value) <= 1, "\(item.id)の帯の太さが\(thickness)で、値の\(value)と違います")
        }
    }

    /// 囲みの区画は「引用」の区画で、見本の囲みも引用だけにする。Xの投稿は設定でオンにしたときだけ出すため、見本に出さない。
    @Test func embedSamplesAreQuotesOnly() throws {
        // Xの投稿を展開するようにしていても、見本には出さない。
        let settings = try makeSettings()
        settings.expandsXPosts = true
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        let configurations = samples.configurations(colorScheme: .light, revision: 0)

        #expect(configurations.contains { $0.embed?.id.hasPrefix("quote:") == true })
        #expect(!configurations.contains { $0.embed?.id.hasPrefix("x:") == true })
    }

    /// 割合の項目の説明は項目ごとに決まり、縦長の比率の説明がほかの割合の項目に出ない。
    @Test func ratioNotesBelongToTheirItems() {
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.mediaTallestAspectRatio) == "小さいほど縦長のまま出す")
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.reactionGlowIconOpacity) == nil)
        // カスタム絵文字の倍率は、見出しに割合の基準を書かず、1がどの大きさかを説明に出す。名前の行と本文で同じ説明にする。
        for item in [AppearanceCatalog.customEmojiScale, AppearanceCatalog.nameCustomEmojiScale] {
            #expect(AppearanceValueRow.ratioNote(for: item) == "1で絵文字と同じ大きさ", "\(item.id)")
        }
        // 普通の絵文字の倍率は、1でいつもの大きさなのが倍率から分かるので、説明を出さない。
        for item in [AppearanceCatalog.unicodeEmojiScale, AppearanceCatalog.nameUnicodeEmojiScale, AppearanceCatalog.emojiOnlyScale] {
            #expect(AppearanceValueRow.ratioNote(for: item) == nil, "\(item.id)")
        }
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.linkCardImageWidthRatio) == "画像はカードの高さの正方形より広くならない")
    }

    /// 見本の行を幅402で並べ、行ごとの部品の枠を返す。
    /// - Parameter excluding: 除く見本の投稿のID。
    private func layOutSamples(_ settings: AppSettings, groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceFocus? = nil, excluding excluded: String? = nil) -> [AppearancePreviewFrames] {
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 6_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        // 見本の中身は、見本の投稿と同じ順に並ぶ。
        let entries = samples.entries(colorScheme: .light, groups: groups, focus: focus)
        let configurations = samples.configurations(colorScheme: .light, revision: 0, groups: groups, focus: focus)
        let kept = zip(entries, configurations).filter { entry, _ in
            guard let excluded, case .status(let status) = entry else { return true }
            return status.id != excluded
        }
        // 返信でつながった隣の投稿を除いたら線を引かないよう、残した見本だけでつながりを決め直す。
        let connections = ReplyConnection.connections(in: kept.map(\.0))
        preview.apply(kept.map { entry, configuration in
            var configuration = configuration
            configuration.replyConnection = connections[entry.id] ?? ReplyConnection()
            return configuration
        })
        preview.layoutIfNeeded()
        return preview.rowFrames()
    }

    /// ブーストした人のアイコンを文字より大きくしても、名前の上の行がアイコンの高さまで広がり、名前の行に重ならない。
    @Test func largeBoosterAvatarDoesNotOverlapNameRow() throws {
        let settings = try makeSettings()
        settings.setValue(60, for: AppearanceCatalog.boosterAvatarSize)
        settings.setValue(0, for: AppearanceCatalog.contextSpacing)
        let row = try #require(layOutSamples(settings).first { $0[.contextAvatar] != nil })
        let avatar = try #require(row[.contextAvatar]?.first)
        let name = try #require(row[.nameRow]?.first)
        #expect(avatar.minY >= 0)
        #expect(avatar.maxY <= name.minY + 0.5)
    }

    /// 名前の後ろに添える部分を名前より大きくしても、本文はその文字の字面の下から始まる。
    @Test func largeSecondaryNameDoesNotOverlapBody() throws {
        let settings = try makeSettings()
        settings.setValue(30, for: AppearanceCatalog.nameSecondaryText)
        settings.setValue(0, for: AppearanceCatalog.nameBodySpacing)
        let row = try #require(layOutSamples(settings).first { $0[.nameSecondary] != nil && $0[.bodyGlyphs] != nil })
        let secondary = try #require(row[.nameSecondary]?.first)
        let body = try #require(row[.bodyGlyphs]?.first)
        // ラベルの枠は行の高さ分あるので、字面の下端（枠の下端より上）より下から本文が始まれば重ならない。枠の下端との差は数pt。
        #expect(body.minY >= secondary.maxY - 6)
    }
}

private extension AppearanceHighlight {
    /// すき間を示すか。部品そのものを示すものは、太さが値と一致しないので除く。
    var measuresGap: Bool {
        switch self {
        case .verticalGap, .horizontalGap: true
        case .part(let part): [.mediaTileGaps, .pollOptionGaps, .cardLineGaps, .bodyLineGaps, .bodyParagraphGaps, .visibilitySymbolGap, .editedMarkGap, .nameTimeMinGap].contains(part)
        case .firstOf(let candidates): candidates.first?.measuresGap ?? false
        case .firstPart, .allParts: false
        }
    }
}
