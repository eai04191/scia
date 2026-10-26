import SciaCore
import SciaTesting
import SwiftUI
import Testing
import UIKit
@testable import Scia

@Suite(.scratch)
@MainActor
struct NotificationAppearanceEditorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func layOutPreview(_ settings: AppSettings, height: CGFloat = 4_000) -> AppearancePreviewView {
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        let samples = NotificationAppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: now)
        preview.apply(samples.configurations(colorScheme: .light, revision: 0), highlight: nil)
        preview.layoutIfNeeded()
        return preview
    }

    /// プレビューの見本だけで、どの項目も場所を示せる。
    @Test func samplesShowEveryItem() throws {
        let rows = layOutPreview(.isolated()).rowFrames()
        for item in NotificationAppearanceCatalog.values {
            let highlight = try #require(AppearanceHighlight(item), "\(item.id)に示す場所がありません")
            #expect(highlight.locate(in: rows) != nil, "\(item.id)の場所が見本にありません")
        }
    }

    /// すき間を示す帯の太さは、その項目の値と同じになる。帯がラベルの枠から測られていると、文字の上下の余白の分だけずれる。
    @Test(arguments: NotificationAppearanceCatalog.values.filter { item in
        item.unit == .point && AppearanceHighlight(item)?.measuresNotificationGap == true
    })
    func gapBandMatchesValue(item: AppearanceValue) throws {
        let settings = AppSettings.isolated()
        let value = item.defaultValue + 3
        settings.setValue(value, for: item)
        let rows = layOutPreview(settings).rowFrames()
        let found = try #require(AppearanceHighlight(item)?.locate(in: rows), "\(item.id)の場所が見本にありません")
        for rect in found.rects {
            let thickness = min(rect.width, rect.height)
            #expect(abs(thickness - value) <= 1, "\(item.id)の帯の太さが\(thickness)で、値の\(value)と違います")
        }
    }

    /// 既定値と範囲の両端で、見本を並べて落ちず、どの項目を示しても帯を置く計算が落ちない。
    /// - Parameter extreme: 全項目を最小にするならfalse、最大にするならtrue、既定値のままならnil。
    @Test(arguments: [nil, false, true] as [Bool?])
    func extremesShowEveryItem(extreme: Bool?) throws {
        let settings = AppSettings.isolated()
        if let atMaximum = extreme {
            for item in NotificationAppearanceCatalog.values {
                settings.setValue(atMaximum ? item.range.upperBound : item.range.lowerBound, for: item)
            }
        }
        let preview = layOutPreview(settings, height: 400)
        let samples = NotificationAppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: now)
        let configurations = samples.configurations(colorScheme: .light, revision: 0)
        for item in NotificationAppearanceCatalog.values {
            preview.apply(configurations, highlight: AppearanceHighlight(item))
            preview.layoutIfNeeded()
        }
    }

    /// アイコンやサムネイルの大きさを0にしても、並べたもののあいだの項目は場所を示せる。
    @Test(arguments: [
        (NotificationAppearanceCatalog.groupAvatarSize, NotificationAppearanceCatalog.groupAvatarSpacing),
        (NotificationAppearanceCatalog.quotedThumbnailSize, NotificationAppearanceCatalog.quotedThumbnailSpacing),
    ])
    func gapsShowWithZeroSize(size: AppearanceValue, gap: AppearanceValue) throws {
        let settings = AppSettings.isolated()
        settings.setValue(0, for: size)
        let found = try #require(AppearanceHighlight(gap)?.locate(in: layOutPreview(settings).rowFrames()), "\(gap.id)の場所が見本にありません")
        #expect(!found.rects.isEmpty, "\(gap.id)の帯がありません")
    }

    /// 見本は通知の組み方をひととおり含み、メンションは投稿の行で描く。
    @Test func samplesCoverEveryLayout() {
        let samples = NotificationAppearanceSamples(settings: .isolated(), tuning: TuningStore(defaults: nil), now: now)
        let configurations = samples.configurations(colorScheme: .light, revision: 0)
        #expect(configurations.contains { ($0 as? NotificationContentConfiguration)?.groupAvatars.isEmpty == false })
        #expect(configurations.contains { ($0 as? NotificationContentConfiguration)?.bodyKind == .quotedPost })
        #expect(configurations.contains { ($0 as? NotificationContentConfiguration)?.bodyKind == .account })
        #expect(configurations.contains { $0 is PostContentConfiguration })
    }
}

private extension AppearanceHighlight {
    /// すき間を示すか。部品そのものを示すものは、太さが値と一致しないので除く。
    var measuresNotificationGap: Bool {
        switch self {
        case .verticalGap, .horizontalGap: true
        case .part(let part): [.groupAvatarGaps, .quotedThumbnailGaps, .notificationHeaderAvatarGap].contains(part)
        case .firstOf(let candidates): candidates.first?.measuresNotificationGap ?? false
        case .firstPart, .allParts: false
        }
    }
}
