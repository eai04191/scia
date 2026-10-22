#if DEBUG
import SciaCore
import UIKit

/// 自分のプロフィールの編集画面。サーバーに送らずに、ヘッダー画像の比率ごとの見本、読み込みの途中と失敗、長い文、上限を超えた文、補足情報が上限まである状態、
/// 画像を替える前と消す前、保存の途中を並べる。保存を押しても何も送らない。
enum ProfileEditCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "サーバーに接続できませんでした。" }
    }

    private static let limits = ProfileLimits.beforeMastodon46

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("ふつう", source: source(note: "猫と写真が好きです。\n:blobcat: よろしくお願いします。", fields: [ProfileSource.Field(name: "Web", value: "https://example.com")])) { _ in },
            state("3:2のヘッダー画像", source: source(header: CatalogFixtures.imageURL(width: 1500, height: 1000, color: .systemTeal, label: "3:2"))) { _ in },
            state("ヘッダー画像がない", source: source(header: URL(string: "https://example.com/headers/original/missing.png"))) { _ in },
            state("読み込み中", load: { try await Task.sleep(for: .seconds(3_600)); return source() }) { _ in },
            state("読み込めなかった", load: { throw Failure() }) { _ in },
            state("長い表示名と自己紹介、上限までの補足情報", source: source(
                displayName: "とても長い表示名をつけた人ですとても長い表示名を",
                note: String(repeating: "自己紹介の長い文です。折り返して何行にもなります。", count: 8),
                fields: (1 ... 4).map { ProfileSource.Field(name: "長い名前の補足情報 その\($0)", value: "https://example.com/very/long/path/that/does/not/fit/in/one/line/\($0)") }
            )) { _ in },
            state("上限を超えた") { draft in
                draft.displayName = String(repeating: "長", count: limits.displayName + 3)
                draft.note = String(repeating: "あ", count: limits.note + 10)
                draft.fields = [ProfileFieldDraft(name: "", value: "名前のない内容")]
            },
            state("補足情報の名前が長すぎる") { draft in
                draft.fields = [ProfileFieldDraft(name: String(repeating: "名", count: limits.fieldName + 1), value: "内容")]
            },
            state("保存の途中", save: { _ in try await Task.sleep(for: .seconds(3_600)); return source() }) { draft in
                draft.note = "書き換えた自己紹介"
            } after: { controller in
                Task { _ = try? await controller.editor.save() }
            },
            state("アイコンを替え、ヘッダー画像を消す前") { draft in
                draft.header = .remove
            } after: { controller in
                let preview = DummyMedia.image(size: CGSize(width: 400, height: 400), color: .systemPink, label: "新")
                controller.replaceImage(.avatar, upload: MediaUpload(data: Data(), filename: "avatar.jpg", mimeType: "image/jpeg"), preview: preview)
            },
        ]
    }

    private static func source(
        displayName: String = "カタログ",
        note: String = "",
        fields: [ProfileSource.Field] = [],
        header: URL? = CatalogFixtures.imageURL(width: 1500, height: 500, color: .systemIndigo, label: "3:1")
    ) -> ProfileSource {
        ProfileSource(
            account: CatalogFixtures.account(displayName: displayName, header: header),
            note: note,
            fields: fields
        )
    }

    @MainActor
    private static func state(
        _ title: String,
        source: ProfileSource = source(),
        load: (@Sendable () async throws -> ProfileSource)? = nil,
        save: @escaping @Sendable (ProfileDraft) async throws -> ProfileSource = { _ in ProfileEditCatalog.source() },
        fill: @escaping @MainActor (inout ProfileDraft) -> Void,
        after: @escaping @MainActor (ProfileEditViewController) -> Void = { _ in }
    ) -> CatalogState {
        CatalogState(title: title) {
            let editor = ProfileEditor(limits: limits, api: ProfileEditor.API(source: load ?? { source }, save: save))
            let completion = TextInputCompletion(completion: ComposeCompletion(sources: .unavailable, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)), recentEmojis: nil)
            let controller = ProfileEditViewController(editor: editor, completion: completion)
            Task {
                await editor.load()
                guard var draft = editor.draft else { return }
                fill(&draft)
                editor.draft = draft
                controller.showDraft()
                after(controller)
            }
            return CatalogControllerHost(UINavigationController(rootViewController: controller), height: 720)
        }
    }
}
#endif
