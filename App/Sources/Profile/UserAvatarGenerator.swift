import SciaCore
import SwiftUI
import UIKit

@MainActor
enum UserAvatarGenerator {
    static let colors = AccentColorChoice.allCases.filter { $0 != .monochrome }
    static let colorTraits = UITraitCollection {
        $0.userInterfaceStyle = .light
        $0.accessibilityContrast = .normal
    }

    static func image(symbol: UserAvatarSymbol, color: AccentColorChoice) throws -> UIImage {
        guard UIImage(systemName: symbol.rawValue) != nil else { throw CocoaError(.coderInvalidValue) }
        let renderer = ImageRenderer(content: UserAvatarContent(symbol: symbol, color: color, side: 512))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw CocoaError(.coderInvalidValue) }
        return UIImage(cgImage: image)
    }
}

struct UserAvatarContent: View {
    let symbol: UserAvatarSymbol
    let color: AccentColorChoice
    var side: CGFloat = 64

    var backgroundColor: UIColor { color.uiColor.resolvedColor(with: UserAvatarGenerator.colorTraits) }

    var body: some View {
        SymbolTile(systemImage: symbol.rawValue, color: backgroundColor, squareBackground: true, showsRim: false, side: side, decorationScale: side / SymbolTile.baseSide)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 3)
    }
}
