import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 自己紹介が切った行数に収まるかを測るのは、自己紹介か幅が変わったときだけにする。
/// 一覧はスクロールのたびにヘッダーを並べ直す。そのたびに全文を測り直すと、カスタム絵文字の多い自己紹介でスクロールが引っかかっていた。
@Suite(.scratch)
@MainActor
struct ProfileHeaderNoteTests {
    private static let longNote = (1...30).map { "<p>自己紹介の\($0)行目</p>" }.joined()

    private func content(note: String) -> ProfileHeaderView.Content {
        ProfileHeaderView.Content(
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil, note: note),
            followState: .unknown,
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
            headerDescription: nil
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

    @Test func relayoutDoesNotRemeasureNote() throws {
        let (header, window) = try placeHeader()
        defer { close(window) }
        header.apply(content(note: Self.longNote))
        window.layoutIfNeeded()
        let measured = header.noteMeasurementCount
        #expect(measured > 0)

        for _ in 0..<5 {
            header.setNeedsLayout()
            header.layoutIfNeeded()
        }

        #expect(header.noteMeasurementCount == measured)
    }

    @Test func newNoteOrWidthIsMeasuredAgain() throws {
        let (header, window) = try placeHeader()
        defer { close(window) }
        header.apply(content(note: Self.longNote))
        window.layoutIfNeeded()
        let first = header.noteMeasurementCount

        header.apply(content(note: Self.longNote + "<p>足した行</p>"))
        window.layoutIfNeeded()
        let second = header.noteMeasurementCount
        #expect(second > first)

        window.frame.size.width = 320
        window.layoutIfNeeded()
        #expect(header.noteMeasurementCount > second)
    }
}
