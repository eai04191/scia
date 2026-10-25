import SciaCore
import SwiftUI
import UIKit

/// 設定画面に置く見本の投稿。一覧と同じビューで描き、表示の設定を変えるとその場で描き直す。
struct PostPreview: UIViewRepresentable {
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
    var appearanceValues: [String: Double] = [:]
    /// お気に入りとブーストをした投稿の見本にする。下の端の光を見せるため。
    var showsReactions = false
    var drawsReactionGlowInHDR = true
    let builder: PostContentBuilder
    /// リンクカードの見本の灰色を、外観に合わせて選ぶ。
    @Environment(\.colorScheme) private var colorScheme

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
            content: #"<p>設定を変えると、タイムラインの投稿がこのように表示されます🎉 <a href="https://github.com/eai04191/scia">github.com/eai04191/scia</a></p>"#,
            spoilerText: "",
            url: nil,
            card: previewCard
        )
    }

    /// 見本の投稿を書いたアカウント。ログイン中のアカウントを読まずにすぐ出せるよう、アプリのアイコンを使うSciaのアカウントにする。
    private static let account = Account(
        id: "preview-scia",
        username: "scia",
        acct: "scia",
        displayName: "Scia",
        avatar: PreviewImages.avatarURL()
    )

    private var account: Account { Self.account }

    /// リンクカードの見本。Sciaのリポジトリを指し、画像は、通信しないよう、灰色の地にアプリのアイコンを置いた画像を使う。
    private var previewCard: PreviewCard? {
        URL(string: "https://github.com/eai04191/scia").map {
            PreviewCard(
                url: $0,
                title: "eai04191/scia",
                description: "ストリーミングAPIに対応した、手触りの良いiOS向けMastodonクライアント",
                type: .link,
                providerName: "GitHub",
                image: PreviewImages.cardURL(for: colorScheme == .dark ? .dark : .light)
            )
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
