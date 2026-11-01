#if DEBUG
import SciaCore
import UIKit

/// 自分のプロフィールの編集画面。サーバーに送らずに、ヘッダー画像の比率ごとの見本、読み込みの途中と失敗、長い文、上限を超えた文、補足情報が上限まである状態、
/// 画像を替える前と消す前、保存の途中、注目のハッシュタグと紹介しているユーザーの節の読み込みの途中と失敗と上限超えを並べる。保存を押しても何も送らない。
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
                draft.fields = [ProfileFieldDraft(name: "", value: "ラベルのない内容")]
            },
            state("補足情報のラベルが長すぎる") { draft in
                draft.fields = [ProfileFieldDraft(name: String(repeating: "名", count: limits.fieldName + 1), value: "内容")]
            },
            state("保存の途中", save: { _ in try await Task.sleep(for: .seconds(3_600)); return source() }) { draft in
                draft.note = "書き換えた自己紹介"
            } after: { controller in
                Task { _ = try? await controller.editor.save() }
            },
            state(
                "注目のハッシュタグと紹介しているユーザー（長い名前）",
                featuredTags: { featuredTags },
                endorsements: { endorsedAccounts }
            ) { _ in },
            state(
                "注目のハッシュタグが上限を超えた",
                limits: ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255, featuredTags: 2),
                featuredTags: { featuredTags }
            ) { _ in },
            state(
                "注目のハッシュタグと紹介しているユーザーを読み込み中",
                featuredTags: { try await Task.sleep(for: .seconds(3_600)); return [] },
                endorsements: { try await Task.sleep(for: .seconds(3_600)); return [] }
            ) { _ in },
            state(
                "注目のハッシュタグと紹介しているユーザーを読み込めなかった（押すと読み直す）",
                featuredTags: { throw Failure() },
                endorsements: { throw Failure() }
            ) { _ in },
            state("アイコンを替え、ヘッダー画像を消す前") { draft in
                draft.header = .remove
            } after: { controller in
                let preview = DummyMedia.image(size: CGSize(width: 400, height: 400), color: .systemPink, label: "新")
                controller.replaceImage(.avatar, upload: MediaUpload(data: Data(), filename: "avatar.jpg", mimeType: "image/jpeg"), preview: preview)
            },
        ]
    }

    private static let featuredTags: [FeaturedTag] = [
        FeaturedTag(id: "1", name: "nowplaying", statusesCount: 1_234),
        FeaturedTag(id: "2", name: "猫写真", statusesCount: 312),
        FeaturedTag(id: "3", name: "とても長いハッシュタグの名前で画面の幅を超えてしまうものとても長いハッシュタグ", statusesCount: 0),
    ]

    private static let endorsedAccounts: [Account] = [
        CatalogFixtures.account(displayName: "アリス", acct: "alice"),
        CatalogFixtures.account(displayName: "とても長い表示名で名前の欄に入りきらない人とても長い表示名", acct: "a_very_long_username@a.very.long.server.name.example"),
        CatalogFixtures.account(displayName: "ボブ", acct: "bob@remote.example", avatar: nil),
    ]

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
        limits: ProfileLimits = limits,
        source: ProfileSource = source(),
        load: (@Sendable () async throws -> ProfileSource)? = nil,
        save: @escaping @Sendable (ProfileDraft) async throws -> ProfileSource = { _ in ProfileEditCatalog.source() },
        featuredTags: @escaping @Sendable () async throws -> [FeaturedTag] = { [] },
        endorsements: @escaping @Sendable () async throws -> [Account] = { [] },
        fill: @escaping @MainActor (inout ProfileDraft) -> Void,
        after: @escaping @MainActor (ProfileEditViewController) -> Void = { _ in }
    ) -> CatalogState {
        CatalogState(title: title) {
            let editor = ProfileEditor(limits: limits, api: ProfileEditor.API(source: load ?? { source }, save: save, featuredTags: featuredTags, endorsements: endorsements))
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
