import SwiftUI

/// 候補の1行。左にアイコンか絵文字、右に名前と補足を2段で並べる。長い名前は、名前ごとに`fadingTail`で行末をぼかして切る。
struct CandidateRowLayout<Icon: View, Title: View, Subtitle: View, Trailing: View>: View {
    var subtitleLines = 1
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.subheadline)
                    .lineLimit(1)
                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }
}

extension CandidateRowLayout where Subtitle == EmptyView, Trailing == EmptyView {
    init(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title) {
        self.init(icon: icon, title: title, subtitle: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension CandidateRowLayout where Trailing == EmptyView {
    init(@ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder subtitle: () -> Subtitle) {
        self.init(icon: icon, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}
