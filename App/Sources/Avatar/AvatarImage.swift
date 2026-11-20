import SciaCore
import SwiftUI

/// アカウントのアイコン。タイムラインと同じ読み込みと形にする。
struct AvatarImage: UIViewRepresentable {
    let url: URL?
    let shape: AvatarShape

    func makeUIView(context: Context) -> AvatarView {
        AvatarView(store: AppDependencies.avatarImages)
    }

    func updateUIView(_ view: AvatarView, context: Context) {
        view.apply(AvatarView.Content(url: url, shape: shape, animates: false))
    }

    /// 中身は`UIImageView`で、画像が入るたびに大きさの希望が変わる。そのまま使うとSwiftUIが並べ直し続けて止まったため、決まった大きさにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AvatarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 30)
    }
}
