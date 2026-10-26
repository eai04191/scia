import SciaCore
import SwiftUI
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 「投稿の見た目」のすべての項目と選択肢について、変える前と後の見本の行を、示す場所の帯を重ねて画像に並べる。
/// 示す場所が実際に変わった部分と合っているか、切り替えて表示が崩れないかを、人が目で確かめるためのもの。
/// 確かめるときだけ、`TEST_RUNNER_SCIA_APPEARANCE_SHEETS=1`を付けて走らせる。画像はテストを走らせたアプリの一時フォルダーのAppearanceSheetsに書く。
@Suite(.scratch)
@MainActor
struct AppearanceSheets {
    private static let width: CGFloat = 402
    private static let pairsPerSheet = 5

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCIA_APPEARANCE_SHEETS"] != nil))
    func writeSheets() throws {
        // 走らせたあとに人が見る画像なので、テストの終わりに消さない。決まった名前に毎回書き直すので溜まらない
        // swiftlint:disable:next test_file_without_scratch
        let directory = URL.temporaryDirectory.appending(path: "AppearanceSheets", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pairs: [(title: String, before: UIImage, after: UIImage)] = []
        for item in AppearanceCatalog.values {
            let before = try Self.makeSettings()
            let after = try Self.makeSettings()
            let value = Self.changedValue(of: item)
            after.setValue(value, for: item)
            let highlight = AppearanceHighlight(item)
            pairs.append((
                "\(item.id)「\(item.title)」 \(item.defaultValue) → \(value)",
                Self.render(settings: before, highlight: highlight),
                Self.render(settings: after, highlight: highlight)
            ))
        }
        // 本文の右に小さく出すときにだけ効く項目と、効き方の変わる項目は、その並べ方でも並べる。
        for item in Self.besideBodyItems {
            let before = try Self.makeSettings()
            let after = try Self.makeSettings()
            before.mediaArrangement = .besideBody
            after.mediaArrangement = .besideBody
            let value = Self.changedValue(of: item)
            after.setValue(value, for: item)
            let highlight = AppearanceHighlight(item)
            pairs.append((
                "本文の右に小さく \(item.id)「\(item.title)」 \(item.defaultValue) → \(value)",
                Self.render(settings: before, highlight: highlight),
                Self.render(settings: after, highlight: highlight)
            ))
        }
        for choice in AppearanceChoice.allCases {
            let before = try Self.makeSettings()
            let after = try Self.makeSettings()
            let description = Self.change(choice, in: after)
            pairs.append((
                "選択肢 \(choice) \(description)",
                Self.render(settings: before, highlight: choice.highlight),
                Self.render(settings: after, highlight: choice.highlight)
            ))
        }
        for (index, start) in stride(from: 0, to: pairs.count, by: Self.pairsPerSheet).enumerated() {
            let sheet = Self.sheet(Array(pairs[start..<min(start + Self.pairsPerSheet, pairs.count)]))
            let url = directory.appending(path: String(format: "sheet-%02d.png", index))
            try #require(sheet.pngData()).write(to: url)
        }
    }

    private static let besideBodyItems = [AppearanceCatalog.mediaBesideSide, AppearanceCatalog.bodyMediaSpacing, AppearanceCatalog.bodyLinkCardSpacing, AppearanceCatalog.filterNoteSpacing]

    /// 既定値の設定。名前の上の行の添える部分の項目も確かめられるよう、ブーストした人の表記は名前とハンドルにする。
    private static func makeSettings() throws -> AppSettings {
        let settings = AppSettings.isolated()
        settings.contextNameStyle = .nameAndAcct
        return settings
    }

    /// 変えた後の値。違いが目で分かるくらい、既定値から動かす。
    private static func changedValue(of item: AppearanceValue) -> Double {
        let delta = switch item.unit {
        case .point: 10.0
        case .bodyTextOffset, .textOffset: 6.0
        case .ratio: (item.range.upperBound - item.range.lowerBound) * 0.25
        case .lines: 2.0
        }
        let raised = item.defaultValue + delta
        return raised <= item.range.upperBound ? raised : max(item.defaultValue - delta, item.range.lowerBound)
    }

    /// 選択肢を変え、何から何に変えたかを返す。選択肢を足したら、ここにも足さないとコンパイルできない。
    private static func change(_ choice: AppearanceChoice, in settings: AppSettings) -> String {
        func flip(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> String {
            settings[keyPath: keyPath].toggle()
            return "→ \(settings[keyPath: keyPath])"
        }
        switch choice {
        case .contextNameStyle:
            settings.contextNameStyle = .acctOnly
            return "→ ハンドル"
        case .showsContextSymbol: return flip(\.showsContextSymbol)
        case .boldsName: return flip(\.boldsName)
        case .showsAvatarBorder: return flip(\.showsAvatarBorder)
        case .showsMediaBadges: return flip(\.showsMediaBadges)
        case .showsLinkCard: return flip(\.showsLinkCard)
        case .boldsLinkCardTitle: return flip(\.boldsLinkCardTitle)
        case .showsSeparators: return flip(\.showsSeparators)
        case .showsBoosterAvatar: return flip(\.showsBoosterAvatar)
        case .showsReplyLabel: return flip(\.showsReplyLabel)
        case .showsReplyLines: return flip(\.showsReplyLines)
        case .showsTime: return flip(\.showsTime)
        case .showsLinkCardImage: return flip(\.showsLinkCardImage)
        case .showsVisibilitySymbol: return flip(\.showsVisibilitySymbol)
        case .showsEditedMark: return flip(\.showsEditedMark)
        case .showsLinkCardSite: return flip(\.showsLinkCardSite)
        case .avatarShape:
            settings.avatarShape = settings.avatarShape == .circle ? .roundedSquare : .circle
            return "→ \(settings.avatarShape)"
        case .animatesAvatars: return flip(\.animatesAvatars)
        case .nameStyle:
            settings.statusNameStyle = .acctAndName
            return "→ ハンドル、名前"
        case .timeStyle:
            settings.statusTimeStyle = .absolute
            return "→ 日時"
        case .glyphLanguage:
            settings.glyphLanguage = .simplifiedChinese
            return "→ 簡体字中国語"
        case .emojiStyle:
            settings.emojiStyle = .twemoji
            return "→ Twemoji"
        case .animatesCustomEmojis: return flip(\.animatesCustomEmojis)
        case .linkCardThumbnailSide:
            settings.linkCardThumbnailSide = .right
            return "→ 右"
        case .mediaArrangement:
            settings.mediaArrangement = .besideBody
            return "→ 本文の右に小さく"
        case .drawsReactionGlowInHDR: return flip(\.drawsReactionGlowInHDR)
        case .reactionGlowIcons:
            settings.reactionGlowIcons = .atBottom
            return "→ 下の端に1つずつ"
        case .reactionGlowFillsWidthWhenAlone: return flip(\.reactionGlowFillsWidthWhenAlone)
        case .reactionGlowLightFavouriteColor:
            settings.reactionGlowLightFavouriteColor = .yellow
            return "→ 黄色"
        }
    }

    /// 示す場所のある見本の行を、帯を重ねて描く。示す場所が見つからなければ、そのことを書いた画像にする。
    private static func render(settings: AppSettings, highlight: AppearanceHighlight?) -> UIImage {
        let preview = AppearancePreviewView(frame: CGRect(x: 0, y: 0, width: width, height: 6_000))
        let samples = AppearanceSamples(settings: settings, tuning: TuningStore(defaults: nil), now: Date(timeIntervalSince1970: 1_800_000_000))
        preview.apply(samples.configurations(colorScheme: .light, revision: 0), highlight: nil, showsSeparators: settings.showsSeparators)
        preview.layoutIfNeeded()
        guard let highlight, let found = highlight.locate(in: preview.rowFrames()) else {
            return label("示す場所が見本にない", size: CGSize(width: width, height: 40))
        }
        let row = preview.rowViews[found.row]
        return UIGraphicsImageRenderer(bounds: row.bounds).image { context in
            UIColor.systemBackground.setFill()
            context.fill(row.bounds)
            row.layer.render(in: context.cgContext)
            // アプリのプレビューと同じく、部品は外側に枠を引き、場所は塗る。
            for rect in found.rects {
                var band = rect.insetBy(dx: min((rect.width - 2) / 2, 0), dy: min((rect.height - 2) / 2, 0))
                let encloses = found.style == .enclose
                if encloses {
                    band = band.insetBy(dx: -AppearancePreviewView.encloseOutset, dy: -AppearancePreviewView.encloseOutset)
                }
                UIColor.systemRed.withAlphaComponent(encloses ? 0.06 : 0.25).setFill()
                // fill(_:)は下の画素を置き換えるので、文字が隠れないよう重ねて塗る。
                context.fill(band, blendMode: .normal)
                UIColor.systemRed.setStroke()
                context.stroke(band)
            }
        }
    }

    private static func label(_ text: String, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.systemYellow.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)])
        }
    }

    /// 組ごとに、題と、変える前と後の画像を左右に並べる。
    private static func sheet(_ pairs: [(title: String, before: UIImage, after: UIImage)]) -> UIImage {
        let gap: CGFloat = 12
        let titleHeight: CGFloat = 28
        let heights = pairs.map { titleHeight + max($0.before.size.height, $0.after.size.height) + gap }
        let size = CGSize(width: width * 2 + gap * 3, height: heights.reduce(0, +) + gap)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGray5.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var y = gap
            for (pair, height) in zip(pairs, heights) {
                (pair.title as NSString).draw(at: CGPoint(x: gap, y: y + 4), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: UIColor.black])
                pair.before.draw(at: CGPoint(x: gap, y: y + titleHeight))
                pair.after.draw(at: CGPoint(x: gap * 2 + width, y: y + titleHeight))
                y += height
            }
        }
    }
}
