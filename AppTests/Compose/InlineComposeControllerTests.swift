import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄を実際のウィンドウに載せ、開閉や返信先の付け替えで行が崩れないことを確かめる。
@MainActor
@Suite(.serialized)
struct InlineComposeControllerTests {
    private let window: UIWindow
    private let composer: InlineComposeController

    init() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "テストのホストアプリにウィンドウシーンがありません"
        )
        let tabBarController = UITabBarController(tabs: [UITab(title: "ホーム", image: nil, identifier: "home") { _ in UIViewController() }])
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        composer = InlineComposeController(model: ComposeModel(myAccountID: "1") { _ in }, tuning: TuningStore(defaults: nil))
        composer.install(in: tabBarController)
        window.layoutIfNeeded()
    }

    private func status(id: String) throws -> Status {
        Status(
            id: id,
            createdAt: .now,
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "",
            url: nil
        )
    }

    /// 開閉のアニメーションの途中で、返信先の変更が反映されても、返信先の札の行と入力欄が重ならない。
    @Test func replyRowKeepsItsSpaceAcrossRepeatedReplies() async throws {
        defer { window.isHidden = true }
        for round in 0..<4 {
            composer.reply(to: try status(id: "\(10 + round)"))
            try await Task.sleep(for: .milliseconds(700))
            window.layoutIfNeeded()
            #expect(composer.overlappingRows.isEmpty, "\(round)回目に返信を始めたとき、行が重なりました\n\(composer.stateDump())")

            composer.endEditing()
            try await Task.sleep(for: .milliseconds(700))
            window.layoutIfNeeded()
            #expect(composer.overlappingRows.isEmpty, "\(round)回目に閉じたとき、行が重なりました\n\(composer.stateDump())")
        }
    }

    /// 書いている途中で別の投稿へ返信し直したり、閉じる途中や札を外した直後に返信を始めたりしても、行が重ならない。
    /// 待ち時間を変えて、アニメーションのいろいろな途中に次の操作を送る。
    @Test(arguments: [0, 30, 120, 250])
    func replyRowKeepsItsSpaceWhenInterrupted(waitMilliseconds: Int) async throws {
        defer { window.isHidden = true }
        let wait = Duration.milliseconds(waitMilliseconds)
        composer.reply(to: try status(id: "10"))
        try await Task.sleep(for: wait)
        composer.reply(to: try status(id: "11"))
        try await Task.sleep(for: wait)
        composer.endEditing()
        try await Task.sleep(for: wait)
        composer.reply(to: try status(id: "12"))
        try await Task.sleep(for: wait)
        composer.model.setReplyTarget(nil)
        try await Task.sleep(for: wait)
        composer.reply(to: try status(id: "13"))
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()

        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 投稿へ返信したあと、同じ投稿のブーストを返信に選び直しても、札が縮まず宛先の文字を収める。
    @Test func replyChipKeepsWidthWhenReselectingBoostOfSameStatus() async throws {
        defer { window.isHidden = true }
        let original = try status(id: "10")
        let booster = Account(id: "3", username: "carol", acct: "carol", displayName: "Carol", avatar: URL(string: "https://example.social/c.png"))
        let boost = Status(id: "20", createdAt: .now, account: booster, content: "", spoilerText: "", url: nil, reblog: original)

        composer.reply(to: original)
        try await Task.sleep(for: .milliseconds(700))
        composer.reply(to: boost)
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()

        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })
        #expect(button.configuration?.title == "@bobへの返信")
        expectChipFitsTitle(button)
    }

    /// 札を外すと、行は薄くなりながら縮み、外し終えたら隠れる。消えていく途中も札の文字は残る。
    @Test func clearingReplyFadesOutRow() async throws {
        defer { window.isHidden = true }
        composer.reply(to: try status(id: "10"))
        try await Task.sleep(for: .milliseconds(700))
        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })

        composer.model.setReplyTarget(nil)
        try await Task.sleep(for: .milliseconds(80))
        let presentation = try #require(button.superview?.layer.presentation())
        #expect(presentation.opacity > 0 && presentation.opacity < 1, "札がパッと消えました: opacity=\(presentation.opacity)")
        #expect(button.configuration?.title?.hasSuffix("への返信") == true, "消えていく途中で札の文字が消えました")

        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        #expect(button.superview?.isHidden == true)
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 札が消えていく途中に別の投稿の返信を選んでも、札は出たままで崩れない。
    @Test func replyingWhileReplyRowFadesOut() async throws {
        defer { window.isHidden = true }
        composer.reply(to: try status(id: "10"))
        try await Task.sleep(for: .milliseconds(700))

        composer.model.setReplyTarget(nil)
        try await Task.sleep(for: .milliseconds(100))
        composer.reply(to: try status(id: "11"))
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()

        let button = try #require(buttons(in: window).first { $0.configuration?.title?.hasSuffix("への返信") == true })
        let row = try #require(button.superview)
        #expect(!row.isHidden && row.alpha == 1, "札が出ていません: hidden=\(row.isHidden) alpha=\(row.alpha)")
        expectChipFitsTitle(button)
        #expect(composer.overlappingRows.isEmpty, "行が重なりました\n\(composer.stateDump())")
    }

    /// 札の文字が省略も切り取りもされずに収まっている。文字ラベルが本来の幅を確保し、札がその文字を囲んでいる。
    /// 添付の長押しでメニューを出すと、iOSがソフトウェアキーボードを隠す。その間もバーを今の位置に留め、キーボードが戻ったら外す。
    @Test func contextMenuHoldsBarUntilKeyboardReturns() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await Task.sleep(for: .milliseconds(500))
        postKeyboardFrame(height: 336)

        showContextMenu()
        #expect(composer.isBarHeld, "メニューを出しても、バーを留めていません\n\(composer.stateDump())")
        postKeyboardFrame(height: 0)
        endContextMenu()
        #expect(composer.isBarHeld, "キーボードが戻る前に、バーを外しました\n\(composer.stateDump())")
        postKeyboardFrame(height: 336)
        #expect(!composer.isBarHeld, "キーボードが戻っても、バーを留めたままです\n\(composer.stateDump())")
    }

    /// ハードウェアキーボードのようにキーボードが隠れなければ、メニューを閉じた時点でバーを外す。
    @Test func contextMenuReleasesBarWhenKeyboardStayed() async throws {
        defer { window.isHidden = true }
        composer.beginEditing()
        try await Task.sleep(for: .milliseconds(500))
        postKeyboardFrame(height: 336)

        showContextMenu()
        endContextMenu()
        #expect(!composer.isBarHeld, "メニューを閉じても、バーを留めたままです\n\(composer.stateDump())")
    }

    private func showContextMenu() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        composer.attachmentStrip.collectionView(collectionView, willDisplayContextMenu: UIContextMenuConfiguration(), animator: nil)
    }

    private func endContextMenu() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        composer.attachmentStrip.collectionView(collectionView, willEndContextMenuInteraction: UIContextMenuConfiguration(), animator: nil)
    }

    /// 画面の下端から`height`だけキーボードが上がった、という知らせを送る。0なら隠れた。
    private func postKeyboardFrame(height: CGFloat) {
        let frame = CGRect(x: 0, y: window.bounds.maxY - height, width: window.bounds.width, height: height)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
    }

    private func expectChipFitsTitle(_ button: UIButton, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let label = button.titleLabel else {
            Issue.record("札に文字ラベルがありません", sourceLocation: sourceLocation)
            return
        }
        #expect(label.bounds.width >= label.intrinsicContentSize.width - 0.5, "札の文字が縮んでいます: \(label.bounds.width) / \(label.intrinsicContentSize.width)\n\(composer.stateDump())", sourceLocation: sourceLocation)
        #expect(button.bounds.width >= label.frame.maxX, "札が文字より狭くなりました\n\(composer.stateDump())", sourceLocation: sourceLocation)
    }

    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }
}
