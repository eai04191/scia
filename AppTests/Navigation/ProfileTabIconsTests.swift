import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// タブに置いたプロフィールで、記号の代わりに出すその人のアイコン。決まりはdocs/tabs.mdの「プロフィール」にある。
@Suite(.scratch)
@MainActor
struct ProfileTabIconsTests {
    private static let bob = TabItem.profile(accountID: "2", acct: "bob")

    private static let avatar = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in
        UIColor.red.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    /// アイコンを読むまでと、プロフィールでない項目には出さない。読んだら、タブとメニューの大きさで、元の色のまま描く。
    @Test func iconAppearsOnceAvatarIsSet() throws {
        let icons = ProfileTabIcons(settings: .isolated())
        var changes = 0
        icons.onChange = { changes += 1 }
        #expect(icons.icon(for: Self.bob) == nil)

        icons.setAvatar(Self.avatar, forAccountID: "2")

        let icon = try #require(icons.icon(for: Self.bob))
        #expect(changes == 1)
        #expect(icons.revision == 1)
        #expect(icons.hasAvatar(for: Self.bob))
        #expect(icon.tab.size == CGSize(width: ProfileTabIcons.tabSide, height: ProfileTabIcons.tabSide))
        #expect(icon.selectedTab.size == icon.tab.size)
        #expect(icon.menu.size == CGSize(width: AvatarIcon.menuSide, height: AvatarIcon.menuSide))
        #expect([icon.tab, icon.selectedTab, icon.menu].allSatisfy { $0.renderingMode == .alwaysOriginal })
        #expect(icons.icon(for: .home) == nil)
        #expect(icons.icon(for: .profile(accountID: "3", acct: "carol")) == nil)
    }

    /// 選んでいるときは、縁の内側に縮めたアイコンを置き、角は縁の色になる。縁はアクセントカラーで描く。
    @Test func selectedIconHasRing() throws {
        let settings = AppSettings.isolated()
        settings.accentColor = .orange
        let icons = ProfileTabIcons(settings: settings)
        icons.setAvatar(Self.avatar, forAccountID: "2")
        let icon = try #require(icons.icon(for: Self.bob))

        // 縁の上の点は選んだ色、縁とアイコンの間は透明、真ん中はアイコンの色。
        let side = ProfileTabIcons.tabSide
        #expect(try Self.color(of: icon.selectedTab, at: CGPoint(x: side / 2, y: 0.5)).isClose(to: Self.drawnColor(.systemOrange)))
        #expect(try Self.color(of: icon.selectedTab, at: CGPoint(x: side / 2, y: 3)).alpha == 0)
        #expect(try Self.color(of: icon.selectedTab, at: CGPoint(x: side / 2, y: side / 2)).isClose(to: UIColor.red.resolvedRGBA))
    }

    /// アイコンの形の設定を変えたら、出し直させる。
    @Test func shapeChangeAsksToRefresh() async throws {
        let settings = AppSettings.isolated()
        let icons = ProfileTabIcons(settings: settings)
        var changes = 0
        icons.onChange = { changes += 1 }

        settings.appearance.avatarShape = settings.appearance.avatarShape == .circle ? .roundedSquare : .circle

        try await waitUntil { changes == 1 }
    }

    /// 並びから外したプロフィールのアイコンは捨てる。
    @Test func removedAvatarIsForgotten() {
        let icons = ProfileTabIcons(settings: .isolated())
        icons.setAvatar(Self.avatar, forAccountID: "2")
        icons.setAvatar(Self.avatar, forAccountID: "3")

        let revision = icons.revision

        icons.removeAvatars(except: ["3"])

        #expect(icons.revision == revision + 1)
        #expect(icons.icon(for: Self.bob) == nil)
        #expect(icons.icon(for: .profile(accountID: "3", acct: "carol")) != nil)
    }

    /// `color`を、アイコンと同じ端末の広い色空間で描いてから読んだ色。鮮やかな色は、読み出すときの変換で`isClose`の幅より大きくずれるため、同じ変換を通して比べる。
    private static func drawnColor(_ color: UIColor) throws -> RGBA {
        let format = UIGraphicsImageRendererFormat.preferred()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try Self.color(of: image, at: .zero)
    }

    private static func color(of image: UIImage, at point: CGPoint) throws -> RGBA {
        let cgImage = try #require(image.cgImage)
        let scale = image.scale
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return RGBA(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }
}

private struct RGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    /// 画像は端末の広い色空間で描くため、読み出すときの変換で成分が少しずれる。そのずれを同じとみなす。
    func isClose(to other: RGBA) -> Bool {
        [(red, other.red), (green, other.green), (blue, other.blue), (alpha, other.alpha)].allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }
}

private extension UIColor {
    /// 明るい見た目での色を、8ビットの成分にする。
    var resolvedRGBA: RGBA {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: UInt8((red * 255).rounded()), green: UInt8((green * 255).rounded()), blue: UInt8((blue * 255).rounded()), alpha: UInt8((alpha * 255).rounded()))
    }
}
