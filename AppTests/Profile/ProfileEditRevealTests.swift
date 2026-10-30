import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// プロフィールの編集を開いたとき、読み込み中の表示から入力欄を出すまで。
@Suite(.scratch)
@MainActor
struct ProfileEditRevealTests {
    private struct NotSaved: Error {}

    private let clock = TestClock()

    private static let avatarURL = URL(string: "https://example.social/avatars/alice.png")
    private static let headerURL = URL(string: "https://example.social/headers/alice.png")

    private func makeController(images: MediaImageStore<UIImage>) throws -> (ProfileEditViewController, UIWindow) {
        let account = Account(
            id: "1",
            username: "alice",
            acct: "alice",
            displayName: "Alice",
            avatar: Self.avatarURL,
            header: Self.headerURL
        )
        let editor = ProfileEditor(
            limits: .beforeMastodon46,
            api: ProfileEditor.API(source: { ProfileSource(account: account, note: "", fields: []) }, save: { _ in throw NotSaved() })
        )
        let tuning = TuningStore(defaults: nil)
        let completion = TextInputCompletion(completion: ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: tuning)), recentEmojis: nil)
        let controller = ProfileEditViewController(editor: editor, completion: completion, mediaImages: images, settings: .isolated(), tuning: tuning, clock: clock)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        return (controller, window)
    }

    /// 窓を隠し、編集の画面を外す。外さないと、隠した窓に編集の画面が残り、あとのテストの窓の扱い（ステータスバーの通知、チップの位置）を変えるため。
    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func tableView(of controller: ProfileEditViewController) throws -> UITableView {
        try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
    }

    /// 出している画像の欄のアイコンが、読み込んだ画像になっている。人の記号のままならfalse。
    private func showsAvatarImage(in table: UITableView) -> Bool {
        table.layoutIfNeeded()
        return table.descendants(of: UIImageView.self).contains { $0.contentMode == .scaleAspectFill && $0.image != nil && $0.bounds.width == 80 }
    }

    private func png() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    /// アイコンを読み終えるまでは、入力欄を出さずに読み込み中の表示を続ける。読み終えたら、アイコンの画像が入った状態で出す。
    /// 出したあとに、人の記号からアイコンへ1コマで替わらないようにするため。
    @Test func waitsForAvatarBeforeShowingFields() async throws {
        let gate = Gate()
        let data = try png()
        let images = MediaImageStore(files: .temporary()) { _, _ in
            try await gate.wait()
            return data
        }
        let (controller, window) = try makeController(images: images)
        defer { close(window) }
        let table = try tableView(of: controller)
        try await waitUntil { controller.editor.draft != nil && clock.sleeperCount > 0 }
        #expect(table.isHidden, "アイコンを待つ間に入力欄を出しました")

        gate.open()
        try await waitUntil { !table.isHidden }
        #expect(showsAvatarImage(in: table))
    }

    /// 上限を過ぎてアイコンが届いたらクロスフェードで入れ、すぐあとにヘッダー画像が届いても、アイコンのクロスフェードをかけ直さない。
    /// かけ直すと、進んでいる途中のクロスフェードが新しい画像同士の遷移に置き換わり、アイコンが1コマで替わって見えるため。
    @Test func headerArrivalKeepsAvatarCrossfade() async throws {
        let avatarGate = Gate()
        let headerGate = Gate()
        let data = try png()
        let images = MediaImageStore(files: .temporary()) { url, _ in
            try await (url == Self.avatarURL ? avatarGate : headerGate).wait()
            return data
        }
        let (controller, window) = try makeController(images: images)
        defer { close(window) }
        let table = try tableView(of: controller)
        try await waitUntil { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(TuningCatalog.profileAvatarWait.defaultValue))
        try await waitUntil { !table.isHidden }
        table.layoutIfNeeded()
        let avatarView = try #require(table.descendants(of: UIImageView.self).first { $0.bounds.width == 80 })
        // アイコンのクロスフェードが、ヘッダー画像が届くまでの間に実際の時間で終わらないよう、アイコンの層の時間を止める。
        _ = LayerClock(freezing: avatarView.layer)

        avatarGate.open()
        try await waitUntil { avatarView.layer.animation(forKey: kCATransition) != nil }
        let avatarFade = avatarView.layer.animation(forKey: kCATransition)
        // ヘッダー画像の枠は、角を16ptで丸めた、表の幅いっぱいの画像のビュー。
        let headerView = try #require(table.descendants(of: UIImageView.self).first { $0.layer.cornerRadius == 16 })
        #expect(headerView.image == nil)
        headerGate.open()
        try await waitUntil { headerView.image != nil }

        #expect(avatarView.layer.animation(forKey: kCATransition) === avatarFade, "ヘッダー画像が届いたときに、アイコンのクロスフェードをかけ直しました")
    }

    /// アイコンが待つ上限までに届かなければ、待たずに入力欄を出す。
    @Test func showsFieldsAfterWaitLimit() async throws {
        let gate = Gate()
        let images = MediaImageStore(files: .temporary()) { _, _ in
            try await gate.wait()
            throw URLError(.timedOut)
        }
        let (controller, window) = try makeController(images: images)
        defer {
            gate.open()
            close(window)
        }
        let table = try tableView(of: controller)
        try await waitUntil { clock.sleeperCount > 0 }
        #expect(table.isHidden)

        clock.advance(by: .seconds(TuningCatalog.profileAvatarWait.defaultValue))
        try await waitUntil { !table.isHidden }
        #expect(!showsAvatarImage(in: table))
    }
}
