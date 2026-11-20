import SwiftUI

struct ProfileCardMetrics {
    static let contentInset: CGFloat = 14
    static let cornerRadius: CGFloat = 16
}

struct ProfileCustomizationWarning: View {
    let message: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(ProfileCardMetrics.contentInset)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: ProfileCardMetrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
