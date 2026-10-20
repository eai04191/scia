import SciaCore
import SwiftUI
import UIKit

/// 設定画面に置く見本の投稿。一覧と同じビューで描き、表示の設定を変えるとその場で描き直す。
struct PostPreview: UIViewRepresentable {
    let account: Account
    /// 相対時刻の見本として、少し前の時刻にする。
    let createdAt: Date
    // 下の値は描き直しのきっかけに使う。見た目は、ビルダーがAppSettingsとチューニングから直接読む。
    let nameStyle: StatusNameStyle
    let timeStyle: StatusTimeStyle
    let avatarShape: AvatarShape
    let animatesAvatars: Bool
    let linkCardThumbnailSide: LinkCardThumbnailSide
    let glyphLanguage: GlyphLanguage
    let emojiStyle: EmojiStyle
    /// お気に入りとブーストをした投稿の見本にする。下の端の光を見せるため。
    var showsReactions = false
    var drawsReactionGlowInHDR = true
    let builder: PostContentBuilder

    private var status: Status {
        if showsReactions {
            return Status(
                id: "preview-reactions",
                createdAt: createdAt,
                account: account,
                content: "<p>お気に入りとブーストをした投稿は、このように表示されます。</p>",
                spoilerText: "",
                url: nil,
                favourited: true,
                reblogged: true
            )
        }
        return Status(
            id: "preview",
            createdAt: createdAt,
            account: account,
            content: #"<p>設定を変えると、タイムラインの投稿がこのように表示されます🎉 <a href="https://joinmastodon.org/">joinmastodon.org</a></p>"#,
            spoilerText: "",
            url: nil,
            card: previewCard
        )
    }

    /// リンクカードの見本。画像は、通信を増やさないよう、読み込み済みのアカウントのアイコンを使う。
    private var previewCard: PreviewCard? {
        URL(string: "https://joinmastodon.org/").map {
            PreviewCard(url: $0, title: "リンクカードの見本", description: "画像の位置を選べます。", type: .link, providerName: "joinmastodon.org", image: account.avatarStatic)
        }
    }

    private var configuration: PostContentConfiguration {
        builder.configuration(for: status, base: .cell())
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PostContentView {
        let view = PostContentView(configuration: configuration)
        // 名前のカスタム絵文字が届いたら描き直す。
        context.coordinator.view = view
        builder.emojiImages.addListener(owner: context.coordinator) { [weak coordinator = context.coordinator] _ in
            coordinator?.reapply()
        }
        context.coordinator.makeConfiguration = { configuration }
        return view
    }

    func updateUIView(_ view: PostContentView, context: Context) {
        context.coordinator.makeConfiguration = { configuration }
        view.configuration = configuration
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PostContentView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    @MainActor
    final class Coordinator {
        weak var view: PostContentView?
        var makeConfiguration: (() -> PostContentConfiguration)?

        func reapply() {
            guard let view, let makeConfiguration else { return }
            view.configuration = makeConfiguration()
            view.invalidateIntrinsicContentSize()
        }
    }
}
