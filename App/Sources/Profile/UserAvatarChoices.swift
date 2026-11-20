import Observation
import SciaCore
import SwiftUI

@MainActor
@Observable
final class UserAvatarSelection {
    var symbol = UserAvatarSymbol.person
    var color = AccentColorChoice.gray
}

struct UserAvatarPreview: View {
    let selection: UserAvatarSelection
    let shape: AvatarShape

    var body: some View {
        UserAvatarContent(symbol: selection.symbol, color: selection.color)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: shape == .circle ? 32 : 64 * 0.2))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UserDisplayTexts.avatar)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UserAvatarSymbolChoices: View {
    let selection: UserAvatarSelection

    var body: some View {
        VStack(alignment: .leading) {
            Text(UserDisplayTexts.symbol).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))]) {
                ForEach(UserAvatarSymbol.allCases, id: \.self) { symbol in
                    Button { selection.symbol = symbol } label: {
                        Image(systemName: symbol.rawValue)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                            .background(selection.symbol == symbol ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.title)
                    .accessibilityAddTraits(selection.symbol == symbol ? .isSelected : [])
                }
            }
        }
    }
}

struct UserAvatarColorChoices: View {
    let selection: UserAvatarSelection

    var body: some View {
        VStack(alignment: .leading) {
            Text(UserDisplayTexts.backgroundColor).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))]) {
                ForEach(UserAvatarGenerator.colors, id: \.self) { color in
                    Button { selection.color = color } label: {
                        Circle()
                            .fill(Color(uiColor: color.uiColor.resolvedColor(with: UserAvatarGenerator.colorTraits)))
                            .frame(width: 32, height: 32)
                            .padding(4)
                            .overlay { Circle().strokeBorder(selection.color == color ? Color.primary : .clear, lineWidth: 2) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(selection.color == color ? .isSelected : [])
                }
            }
        }
    }
}
