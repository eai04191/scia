import SciaCore
import SwiftUI
import UIKit

/// カスタム絵文字の画像。届いたら描き直す。
struct EmojiImage: UIViewRepresentable {
    /// 描くのに読む画像。動かすなら元の画像、動かさないなら動かない版。
    let url: URL
    /// アニメーションを求めるURL。nilなら動かさない。
    let animationURL: URL?
    let store: EmojiImageStore<UIImage>

    init(_ emoji: some EmojiImageURLs, choice: EmojiImageChoice, store: EmojiImageStore<UIImage>) {
        url = choice.url(of: emoji)
        animationURL = choice.animationURL(of: emoji)
        self.store = store
    }

    func makeUIView(context: Context) -> EmojiImageView {
        let view = EmojiImageView(frame: .zero)
        let coordinator = context.coordinator
        store.addListener(owner: view) { [weak view, weak coordinator] loaded in
            guard let view, let coordinator, let url = coordinator.url else { return }
            if loaded.contains(url) {
                view.stillImage = store.image(for: url)
            }
            if let animationURL = coordinator.animationURL, loaded.contains(animationURL) {
                view.animation = store.animation(for: animationURL)
            }
        }
        return view
    }

    func updateUIView(_ view: EmojiImageView, context: Context) {
        context.coordinator.url = url
        context.coordinator.animationURL = animationURL
        view.stillImage = store.image(for: url)
        view.animation = animationURL.flatMap { store.animation(for: $0) }
    }

    /// アイコンと同じく、画像で大きさの希望が変わらないよう、決まった大きさにする。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EmojiImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 30)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var url: URL?
        var animationURL: URL?
    }
}
