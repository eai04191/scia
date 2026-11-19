import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 設定の「HDRのメディアの明るさ」を、タイムラインのサムネイルと同じくコレクションビューの中にある画像ビューに届ける。
@Suite(.scratch, .failureState)
@MainActor
struct MediaDynamicRangeTraitsTests {
    /// コレクションビューの中の画像にも、選び直した明るさがすぐ効く。窓の`imageDynamicRange`だけでは、コレクションビューが受け継がず、実機ではどれを選んでも控えめなHDRで描かれた。
    @Test func imageInsideCollectionViewFollowsListSetting() async throws {
        let settings = AppSettings(defaults: TestScratch.defaults("MediaDynamicRangeTraitsTests"))
        settings.mediaDynamicRange = .standard
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let windowSettings = WindowSettings(window: window, followsTint: false)
        windowSettings.use(settings)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let collection = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        let imageView = DynamicRangeFollowingImageView()
        collection.addSubview(imageView)
        root.view.addSubview(collection)
        window.layoutIfNeeded()
        #expect(imageView.preferredImageDynamicRange == .standard)

        settings.mediaDynamicRange = .high

        try await waitUntil {
            window.layoutIfNeeded()
            return imageView.preferredImageDynamicRange == .high
        }
    }

    /// タイムラインに足した投稿のサムネイルも、出た時点から設定の明るさで描く。設定を変えたときだけ指定していたので、変えるまでシステムの既定の明るさで描かれた。
    @Test func thumbnailOfNewPostUsesListSetting() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.mediaDynamicRange = .standard
        let windowSettings = WindowSettings(window: harness.window, followsTint: false)
        windowSettings.use(harness.settings)
        harness.window.layoutIfNeeded()
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let media = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900))
        )
        let post = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil, mediaAttachments: [media])

        harness.setStatuses([post])

        let cell = try #require(harness.visibleCell(of: .status(post.id)))
        let images = Self.views(of: DynamicRangeFollowingImageView.self, in: cell)
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { $0.preferredImageDynamicRange == .standard })
    }

    private static func views<View: UIView>(of type: View.Type, in view: UIView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }
}
