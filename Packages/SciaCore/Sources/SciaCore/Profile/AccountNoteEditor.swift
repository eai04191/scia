public import Observation

/// 相手のプロフィールに書く、自分にしか見えないメモの編集の状態。決まりはdocs/profile.mdの「メモ」にある。
/// 文字数の上限は手元で決めない。MastodonはAPIで返さず、サーバーはソースを変えて上限を変えられるため。超えたらサーバーが断って理由を返す。
@MainActor
@Observable
public final class AccountNoteEditor {
    public typealias Save = @Sendable (_ accountID: String, _ comment: String) async throws -> Relationship

    public let accountID: String
    /// 開いたときのメモ。保存したら、保存したメモにする。
    public private(set) var original: String
    public var text: String
    public private(set) var isSaving = false
    private let saveNote: Save

    public init(accountID: String, note: String, save: @escaping Save) {
        self.accountID = accountID
        original = note
        text = note
        saveNote = save
    }

    /// 書いた文字数。Mastodonと同じく、コードポイントで数える。断られたときに削る量の目安として見せる。
    public var length: Int { text.unicodeScalars.count }
    public var hasChanges: Bool { text != original }
    public var canSave: Bool { hasChanges && !isSaving }

    /// 保存し、保存したあとの関係を返す。空なら消す。失敗したら書いたものを残したまま投げる。保存している途中なら投げる。
    public func save() async throws -> Relationship {
        guard !isSaving else { throw CancellationError() }
        isSaving = true
        defer { isSaving = false }
        let saved = try await saveNote(accountID, text)
        original = saved.note
        text = saved.note
        return saved
    }
}
