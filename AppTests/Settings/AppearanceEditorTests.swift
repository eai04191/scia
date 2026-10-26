import SciaCore
import SwiftUI
import Testing
import UIKit
@testable import Scia

@MainActor
struct AppearanceEditorTests {
    private func makeSettings() throws -> AppSettings {
        let suite = "AppearanceEditorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
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

    /// プレビューの見本だけで、どの項目も場所を示せる。Xの投稿の区画は、Xの投稿を出すようにしているときに見本へ足すXの投稿で示す。
    @Test func samplesShowEveryItem() throws {
        let settings = try makeSettings()
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 2_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, includesXPost: true, revision: 0), highlight: nil)
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
        settings.showsMediaBadges = showsBadges
        let row = try #require(layOutSamples(settings).first { $0[.mediaBadgeSlot] != nil })
        let badges = try #require(row[.mediaBadgeSlot])
        let media = try #require(row[.media]?.first)
        for badge in badges {
            #expect(badge.width > 0 && badge.height > 0)
            #expect(media.contains(badge))
            #expect(badge.width < media.width && badge.height < media.height)
        }
    }

    /// プレビューのどの部品をタップしても、何かの項目が開く。
    @Test func everyPartOpensAnItem() {
        for part in AppearancePreviewPart.allCases {
            #expect(AppearanceHighlight.item(selectedBy: part) != nil, "\(part)をタップしても項目が開きません")
        }
    }

    /// 既定値と範囲の両端で、見本の投稿を並べて落ちず、行の高さが有限になる。投稿は起動してすぐ描くため、ある値で落ちると、起動するたびに落ちて設定まで戻れない。
    /// 高さは一覧のセルと同じく、大きな高さを目安に、高さを譲れる優先度で測る。高さの決まらない制約があると、目安の高さまで伸びる。
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
        let configurations = samples.configurations(colorScheme: .light, includesXPost: true, revision: 0)
        for (index, configuration) in configurations.enumerated() {
            let view = PostContentView(configuration: configuration)
            let height = view.systemLayoutSizeFitting(
                CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            #expect(height.isFinite && height > 0 && height < 100_000, "見本の\(index)番目の高さが\(height)になりました")
        }
        // どの項目を示しても、帯を置く計算が落ちない。
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        for item in AppearanceCatalog.values {
            preview.apply(configurations, highlight: AppearanceHighlight(item))
            preview.layoutIfNeeded()
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
        settings.contextNameStyle = .nameAndAcct
        let value = item.defaultValue + 3
        settings.setValue(value, for: item)
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 4_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, includesXPost: true, revision: 0), highlight: nil)
        preview.layoutIfNeeded()
        let found = try #require(AppearanceHighlight(item)?.locate(in: preview.rowFrames()), "\(item.id)の場所が見本にありません")
        for rect in found.rects {
            let thickness = min(rect.width, rect.height)
            #expect(abs(thickness - value) <= 1, "\(item.id)の帯の太さが\(thickness)で、値の\(value)と違います")
        }
    }

    /// Xの投稿の区画は、Xの投稿を出すようにしているときだけ並べる。
    @Test func xPostGroupFollowsTuning() {
        #expect(!AppearanceEditorView.groups(showsXPost: false).contains { $0.id == AppearanceCatalog.xPostGroupID })
        #expect(AppearanceEditorView.groups(showsXPost: true).contains { $0.id == AppearanceCatalog.xPostGroupID })
    }

    /// 割合の項目の説明は項目ごとに決まり、縦長の比率の説明がほかの割合の項目に出ない。
    @Test func ratioNotesBelongToTheirItems() {
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.mediaTallestAspectRatio) == "小さいほど縦長のまま出す")
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.customEmojiScale) == nil)
        #expect(AppearanceValueRow.ratioNote(for: AppearanceCatalog.linkCardImageWidthRatio) == "画像はカードの高さの正方形より広くならない")
    }

    /// 見本の行を幅402で並べ、行ごとの部品の枠を返す。
    private func layOutSamples(_ settings: AppSettings) -> [AppearancePreviewFrames] {
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 6_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, includesXPost: true, revision: 0), highlight: nil)
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
