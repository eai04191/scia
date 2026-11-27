import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// アイコンから作った色を、設定の「アイコンのカラーに合わせる」に従って付けるか外すか。
@Suite(.scratch, .failureState)
@MainActor
struct ProfileHeaderAccentTests {
    private func content(usesAvatarAccent: Bool) -> ProfileHeaderView.Content {
        ProfileHeaderView.Content(
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/avatar.jpg")),
            followState: .notFollowing(locked: false),
            followedBy: false,
            isChangingFollow: false,
            isReloadingRelationship: false,
            showsRelationshipActivity: false,
            tab: .posts,
            postsFilter: ProfilePostsFilter(showsReplies: true, showsBoosts: true),
            avatarShape: .circle,
            animatesAvatar: false,
            animatesCustomEmojis: false,
            glyphLanguage: "ja",
            isRemote: false,
            privateNote: "",
            avatarDescription: nil,
            headerDescription: nil,
            noteLineLimit: ProfileNoteLength.collapsedLineCount,
            usesAvatarAccent: usesAvatarAccent
        )
    }

    /// 色のはっきりしたアイコンを返すヘッダーをウィンドウに置く。返したウィンドウは、テストの終わりに隠す。
    private func placeHeader() throws -> (ProfileHeaderView, UIWindow) {
        let avatar = try #require(DummyMedia.image(size: CGSize(width: 64, height: 64), color: UIColor(red: 0, green: 0.45, blue: 1, alpha: 1), label: "").pngData())
        let header = ProfileHeaderView(
            emojiImages: .offline,
            mediaImages: MediaImageStore(files: .temporary()) { _, _ in throw URLError(.notConnectedToInternet) },
            avatarImages: AvatarImageStore { _ in avatar },
            settings: AppDependencies.settings
        )
        header.accentFadeDuration = 0
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

    @Test func turningOffRemovesAvatarAccentAndTurningOnRestoresIt() async throws {
        let (header, window) = try placeHeader()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var screenTint: UIColor?
        header.onChangeScreenTint = { screenTint = $0 }

        header.apply(content(usesAvatarAccent: true))
        try await waitUntil { header.tintColor != header.superview?.tintColor || screenTint != nil }

        header.apply(content(usesAvatarAccent: false))
        #expect(screenTint == nil)
        #expect(header.tintColor == header.superview?.tintColor)

        // 色を作り直さなくても、オンに戻すと、読み込み済みのアイコンの色をすぐに付ける。
        header.apply(content(usesAvatarAccent: true))
        #expect(header.tintColor != header.superview?.tintColor || screenTint != nil)
    }

    @Test func doesNotTintWhenOffFromStart() async throws {
        let (header, window) = try placeHeader()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var screenTints: [UIColor?] = []
        header.onChangeScreenTint = { screenTints.append($0) }

        header.apply(content(usesAvatarAccent: false))
        // アイコンが届いて色を作ったあとも、付けない。
        try await waitUntil { screenTints.count >= 2 }
        #expect(screenTints.allSatisfy { $0 == nil })
        #expect(header.tintColor == header.superview?.tintColor)
    }
}
