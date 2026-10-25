import SciaCore
import UIKit

/// 投稿の文字の大きさ。本文は、iPhoneの文字サイズが標準のときの本文の大きさに設定の差を足し、ほかの文字は本文との差で決める。
/// どの文字も本文と同じ`UIFontMetrics`で伸び縮みさせるので、iPhoneの文字サイズを変えても釣り合いを保ったまま一緒に大きくなる。
struct PostTypography: Equatable {
    enum Role: CaseIterable {
        case body
        case namePrimary
        case nameSecondary
        case time
        case context
        case contextSecondary
        case contextLabel
        case spoilerButton
        case linkCardTitle
        case linkCardDetail
        case pollFooter
        case filterNote
        case xPostName
        case xPostBody

        var setting: AppearanceValue {
            switch self {
            case .body: AppearanceCatalog.bodyText
            case .namePrimary: AppearanceCatalog.namePrimaryText
            case .nameSecondary: AppearanceCatalog.nameSecondaryText
            case .time: AppearanceCatalog.timeText
            case .context: AppearanceCatalog.contextText
            case .contextSecondary: AppearanceCatalog.contextSecondaryText
            case .contextLabel: AppearanceCatalog.contextLabelText
            case .spoilerButton: AppearanceCatalog.spoilerButtonText
            case .linkCardTitle: AppearanceCatalog.linkCardTitleText
            case .linkCardDetail: AppearanceCatalog.linkCardDetailText
            case .pollFooter: AppearanceCatalog.pollFooterText
            case .filterNote: AppearanceCatalog.filterNoteText
            case .xPostName: AppearanceCatalog.xPostNameText
            case .xPostBody: AppearanceCatalog.xPostBodyText
            }
        }
    }

    /// 本文の文字の基準にする文字の種類。以前は本文をこの大きさで描いていた。
    private static let textStyle = UIFont.TextStyle.subheadline
    /// 差の付いていない、標準の文字サイズでの本文の書体。
    private static let standardDescriptor = UIFontDescriptor.preferredFontDescriptor(
        withTextStyle: textStyle,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    )
    /// 標準の文字サイズでの大きさの下限。差を足して0以下になると、UIKitは0ptを書体の標準の大きさとして扱い、小さくしたつもりが大きくなるため。
    static let minimumPointSize: CGFloat = 1

    /// 役割ごとの差。本文は標準の大きさとの差、ほかは本文との差。
    private var offsets: [Role: CGFloat]
    /// 名前の行の先頭の部分を太字にする。
    private var boldsName: Bool

    @MainActor
    init(settings: AppSettings) {
        offsets = Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0, CGFloat(settings.value(of: $0.setting))) })
        boldsName = settings.boldsName
    }

    private init(offsets: [Role: CGFloat], boldsName: Bool) {
        self.offsets = offsets
        self.boldsName = boldsName
    }

    /// どの差も既定値の文字。
    static let standard = PostTypography(offsets: Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0, CGFloat($0.setting.defaultValue)) }), boldsName: true)

    private func isBold(_ role: Role) -> Bool {
        switch role {
        case .namePrimary: boldsName
        case .spoilerButton: true
        default: false
        }
    }

    /// iPhoneの文字サイズが標準のときの大きさ。
    func standardPointSize(_ role: Role) -> CGFloat {
        let body = Self.standardDescriptor.pointSize + (offsets[.body] ?? 0)
        let size = role == .body ? body : body + (offsets[role] ?? 0)
        return max(size, Self.minimumPointSize)
    }

    /// 標準の文字サイズで`size`にするための、設定の差。本文は標準の大きさとの差、ほかは本文との差。
    func offset(for role: Role, standardPointSize size: CGFloat) -> CGFloat {
        role == .body ? size - Self.standardDescriptor.pointSize : size - standardPointSize(.body)
    }

    /// - Parameter traits: 文字サイズを読む特性。nilなら今の特性に従う。
    func font(_ role: Role, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        var descriptor = Self.standardDescriptor
        if isBold(role), let bold = descriptor.withSymbolicTraits(.traitBold) {
            descriptor = bold
        }
        let font = UIFont(descriptor: descriptor, size: standardPointSize(role))
        return UIFontMetrics(forTextStyle: Self.textStyle).scaledFont(for: font, compatibleWith: traits)
    }
}
