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

    private func content(followState: FollowState, showsRelationshipActivity: Bool = false) -> ProfileHeaderView.Content {
        ProfileHeaderView.Content(
            account: Self.account,
            followState: followState,
            followedBy: false,
            isChangingFollow: false,
            isReloadingRelationship: false,
            showsRelationshipActivity: showsRelationshipActivity,
            tab: .posts,
            postsFilter: ProfilePostsFilter(showsReplies: true, showsBoosts: true),
            avatarShape: .circle,
            animatesAvatar: false,
            animatesCustomEmojis: false,
            glyphLanguage: "ja",
            isRemote: false
        )
    }

    /// ヘッダーを窓に置く。返した窓は、テストの終わりに`close`で外す。
    private func placeHeader() throws -> (ProfileHeaderView, UIWindow) {
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
        header.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
        ])
        return (header, window)
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// 補足情報の行は描き直すたびに作り直す。関係が届いたときのクロスフェードの中で並べると、作ったばかりの行が大きさ0から伸び、
    /// 中の文字が空になったり縦に潰れたりして見えていた。補足情報の行は、クロスフェードより前に並べ終え、動かさない。
    @Test func fieldRowsDoNotAnimateWhenRelationshipArrives() throws {
        let (header, window) = try placeHeader()
        defer { close(window) }
        header.followRevealDuration = 0.3
        header.apply(content(followState: .unknown))
        window.layoutIfNeeded()

        header.apply(content(followState: .following))

        let values = header.descendants(of: LinkLabel.self).filter { ["a.example", "b.example"].contains($0.attributedText?.string) }
        #expect(values.count == 2)
        for label in values {
            #expect(label.bounds.width > 0)
            #expect(label.layer.animationKeys() == nil, "\(label.attributedText?.string ?? ""): \(label.layer.animationKeys() ?? [])")
        }
    }

    /// 関係を待つのが長引いたら、場所を取っておいたボタンの中央にインジケータを出す。関係が届いたら消す。
    @Test func relationshipActivityShowsInsidePlaceholder() throws {
        let (header, window) = try placeHeader()
        defer { close(window) }
        header.apply(content(followState: .unknown))
        window.layoutIfNeeded()
        let indicator = try #require(header.descendants(of: UIActivityIndicatorView.self).first { $0.superview is UIButton })
        let button = try #require(indicator.superview)
        #expect(!indicator.isAnimating)

        header.apply(content(followState: .unknown, showsRelationshipActivity: true))
        window.layoutIfNeeded()
        #expect(indicator.isAnimating)
        #expect(!indicator.isHidden)
        #expect(abs(indicator.center.x - button.bounds.midX) < 0.5)
        #expect(abs(indicator.center.y - button.bounds.midY) < 0.5)

        // 長引いている印が残っていても、関係が届いたら出さない。
        header.apply(content(followState: .following, showsRelationshipActivity: true))
        #expect(!indicator.isAnimating)
    }
}
