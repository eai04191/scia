import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// プロフィールの編集で、項目は送れたが、注目のハッシュタグで断られたあと。
@Suite(.scratch, .failureState)
@MainActor
struct ProfileEditSaveFailureTests {
    private struct Refused: Error {}

    private let clock = TestClock()

    /// 送れた項目を元の値に取り込むと、下書きは作り直され、補足情報の行のIDが替わる。
    /// 表を作り直さないと、行は古いIDのまま残り、そのあとの書き直しが下書きに入らずに捨てられる。
    @Test func fieldEditsAfterPartialSaveReachDraft() async throws {
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        let original = ProfileSource(account: account, note: "", fields: [ProfileSource.Field(name: "サイト", value: "example.com")])
        let editor = ProfileEditor(
            limits: .beforeMastodon46,
            api: ProfileEditor.API(
                source: { original },
                save: { draft in ProfileSource(account: account, note: draft.note, fields: draft.fields.map { ProfileSource.Field(name: $0.name, value: $0.value) }) },
                featuredTags: { [] },
                featureTag: { _ in throw Refused() }
            )
        )
        let tuning = TuningStore(defaults: nil)
        let completion = TextInputCompletion(completion: ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: tuning)), recentEmojis: nil)
        let images = MediaImageStore<UIImage>(files: .temporary()) { _, _ in throw URLError(.timedOut) }
        let controller = ProfileEditViewController(editor: editor, completion: completion, mediaImages: images, settings: .isolated(), tuning: tuning, clock: clock)
        var failures = 0
        controller.onError = { _, _ in failures += 1 }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        try await waitUntil { !table.isHidden && editor.featuredTagsSource.value != nil }

        editor.draft?.note = "書き換えた"
        #expect(editor.addFeaturedTag("魚"))
        let save = try #require(controller.navigationItem.rightBarButtonItem?.primaryAction)
        save.performWithSender(nil, target: nil)
        try await waitUntil { failures >= 1 }

        table.layoutIfNeeded()
        let label = try #require(table.descendants(of: UITextField.self).first { $0.accessibilityLabel == "補足情報のラベル" })
        label.text = "ブログ"
        label.sendActions(for: .editingChanged)

        #expect(editor.draft?.fields.map(\.name) == ["ブログ"])
    }
}
