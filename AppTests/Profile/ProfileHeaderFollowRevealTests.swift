import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// プロフィールを開いたあと、フォローの関係が届いてフォローのボタンをクロスフェードするとき。
@Suite(.scratch)
@MainActor
struct ProfileHeaderFollowRevealTests {
    private static let account = Account(
        id: "1",
        username: "alice",
        acct: "alice",
        displayName: "Alice",
        avatar: nil,
        fields: [
            Account.Field(name: "Website", value: "<a href=\"https://a.example\">a.example</a>"),
            Account.Field(name: "GitHub", value: "<a href=\"https://b.example\">b.example</a>"),
        ]
    )

    private func content(followState: FollowState) -> ProfileHeaderView.Content {
        ProfileHeaderView.Content(
            account: Self.account,
            followState: followState,
            followedBy: false,
            isChangingFollow: false,
            isReloadingRelationship: false,
            tab: .posts,
            postsFilter: ProfilePostsFilter(showsReplies: true, showsBoosts: true),
            avatarShape: .circle,
            animatesAvatar: false,
            animatesCustomEmojis: false,
            glyphLanguage: "ja",
            isRemote: false
        )
    }

    /// 補足情報の行は描き直すたびに作り直す。関係が届いたときのクロスフェードの中で並べると、作ったばかりの行が大きさ0から伸び、
    /// 中の文字が空になったり縦に潰れたりして見えていた。補足情報の行は、クロスフェードより前に並べ終え、動かさない。
    @Test func fieldRowsDoNotAnimateWhenRelationshipArrives() throws {
        let header = ProfileHeaderView(
            emojiImages: .offline,
            mediaImages: MediaImageStore(files: .temporary()) { _, _ in throw URLError(.notConnectedToInternet) },
            avatarImages: .offline
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
        ])
        header.followRevealDuration = 0.3
        header.apply(content(followState: .unknown))
        root.view.layoutIfNeeded()

        header.apply(content(followState: .following))

        let values = header.descendants(of: LinkLabel.self).filter { ["a.example", "b.example"].contains($0.attributedText?.string) }
        #expect(values.count == 2)
        for label in values {
            #expect(label.bounds.width > 0)
            #expect(label.layer.animationKeys() == nil, "\(label.attributedText?.string ?? ""): \(label.layer.animationKeys() ?? [])")
        }
    }
}
